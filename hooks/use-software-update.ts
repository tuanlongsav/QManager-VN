"use client";

import { useState, useCallback, useRef, useEffect } from "react";
import { authFetch, isSessionRedirectInFlight } from "@/lib/auth-fetch";
import { navigateForAuth, prepareForReboot } from "@/lib/session";
import {
  readStorageValueOrNull,
  writeStorageValue,
} from "@/lib/browser-storage";

// =============================================================================
// useSoftwareUpdate — Check, download, install QManager updates
// =============================================================================
// Checks GitHub Releases via the backend CGI on mount.
// Two-step flow: download + verify → install. Polls status during both phases.
//
// Backend: GET/POST /cgi-bin/quecmanager/system/update.sh
// =============================================================================

const CGI_ENDPOINT = "/cgi-bin/quecmanager/system/update.sh";
const POLL_INTERVAL = 2000;
const LAST_CHECKED_KEY = "qm_update_last_checked";

/**
 * Consecutive rejected status polls before we conclude the device is rebooting.
 *
 * One rejection is what a blink looks like while the installer pegs this ARMv7
 * CPU, and acting on it is expensive: prepareForReboot() clears the login
 * cookie and sends the user to a countdown page for a reboot that never
 * happened. Two ticks costs ~4s out of the worker's 20s reboot_ack budget
 * (REBOOT_ACK_TIMEOUT in scripts/usr/bin/qmanager_update), which it has to
 * spare — and the worker reboots on its own once that budget runs out anyway.
 */
const REBOOT_INFERENCE_STRIKES = 2;

/**
 * Consecutive polls a leftover "ready" must survive before the chained install
 * will act on it. See startChainedPolling for why a fresh download can still be
 * reading the previous run's status.
 */
const STALE_READY_TICKS = 3;

/**
 * How long the reported status may sit completely unchanged before we stop
 * believing a worker is behind it.
 *
 * Generous on purpose: the installer streams a new message per step, so any
 * live install resets this long before it expires.
 */
const STALL_TIMEOUT_MS = 10 * 60_000;

/**
 * Hand the tab over to the reboot countdown, shared by both install pollers.
 *
 * Two decisions worth stating, because /reboot/ is the one navigation in this
 * app that is NOT an auth redirect:
 *
 * 1. **It does not spend the auth budget.** The budget counts consecutive gate
 *    hops so a /login/ ↔ /dashboard/ ping-pong gets stopped; /reboot/ is a
 *    terminal page that redirects nowhere, and the device is about to go down
 *    behind it, so it cannot be a lap of any cycle. Counting it would only make
 *    an ordinary OTA install eat a third of the allowance a real loop needs.
 * 2. **It does respect the in-flight latch.** That part is not optional. An href
 *    assignment while a /login/ document is on the wire aborts that load and
 *    starts another, which on this hardware is seconds of a page that never
 *    settles. This file already consulted the latch at three other points and
 *    then skipped it in exactly the two places that navigate — an inconsistency
 *    inside a single file, and the reason this helper exists rather than the two
 *    identical closures that used to sit inside the pollers.
 *
 * The early return is the latch check for the paths that reach here without one
 * (the network-strike branches, which see a rejected fetch rather than a 401).
 * Bailing before prepareForReboot matters: that call clears the login cookie, so
 * running it for a navigation that will be suppressed would log the user out of
 * whatever document is already arriving.
 */
function handOffToRebootPage(): void {
  if (isSessionRedirectInFlight()) return;

  // A marker that could not be written means /reboot/ would bounce the visit
  // straight back to "/" (see components/reboot/reboot-countdown.tsx), landing
  // the user on a dashboard whose every request is about to fail. /login/ is the
  // better place to wait out a reboot that has already been requested.
  const staged = prepareForReboot();
  navigateForAuth(staged ? "/reboot/" : "/login/", { countsAsBounce: false });
}

/** Loosely-typed view of an update.sh reply — every field is optional on the wire. */
export interface CgiJson {
  success?: boolean;
  error?: string;
  detail?: string;
  status?: string;
  message?: string;
  version?: string;
  size?: string;
  /**
   * Whether a systemd timer is actually armed — a different question from
   * whether the preference was saved. Absent means UNKNOWN (a device predating
   * the field never sends it), not false.
   */
  schedule_armed?: boolean;
  /** Present only when `schedule_armed` disagrees with what was requested. */
  schedule_apply_error?: string;
}

/**
 * Parse a CGI reply, returning null rather than throwing.
 *
 * Keeping this out of the pollers' try/catch is the point: a fetch that rejects
 * means the device stopped answering, while a body that will not parse means it
 * answered with something broken. The pollers navigate away on the first and
 * must not on the second — jq lives on the Entware volume at /opt, so an empty
 * 200 is an ordinary platform hiccup, not a reboot.
 */
async function readJson(resp: Response): Promise<CgiJson | null> {
  try {
    const parsed: unknown = await resp.json();
    return parsed && typeof parsed === "object" ? (parsed as CgiJson) : null;
  } catch {
    return null;
  }
}

/** Statuses the stepper has a slot for. */
const STEPPER_STATUSES: ReadonlySet<string> = new Set([
  "idle",
  "downloading",
  "installing",
  "rebooting",
  "error",
]);

/**
 * Narrow a raw status file into the stepper's vocabulary.
 *
 * qmanager_update also writes "verifying", "ready" and "starting" (see its
 * write_status calls), none of which UpdateStatus declares. Casting the reply
 * would put those strings into a field the UI indexes by; collapsing them into
 * the download step keeps the type honest and the stepper on the right rung.
 */
function toUpdateStatus(json: CgiJson, fallbackVersion?: string): UpdateStatus {
  const raw = json.status ?? "";
  const status: UpdateStatus["status"] = STEPPER_STATUSES.has(raw)
    ? (raw as UpdateStatus["status"])
    : raw === "verifying" || raw === "ready" || raw === "starting"
      ? "downloading"
      : "idle";

  return {
    status,
    message: json.message,
    version: json.version || fallbackVersion,
    size: json.size,
  };
}

// ─── Types ──────────────────────────────────────────────────────────────────

export interface AvailableVersion {
  tag: string;
  has_assets: boolean;
  asset_size: string | null;
  is_current: boolean;
}

export interface DownloadState {
  status: "downloading" | "verifying" | "ready" | "error";
  version: string;
  message?: string;
  size?: string;
}

export interface UpdateInfo {
  current_version: string;
  latest_version: string | null;
  update_available: boolean;
  changelog: string | null;
  current_changelog: string | null;
  download_url: string | null;
  download_size: string | null;
  available_versions: AvailableVersion[];
  download_state: DownloadState | null;
  include_prerelease: boolean;
  auto_update_enabled: boolean;
  auto_update_time: string;
  check_error: string | null;
}

export interface UpdateStatus {
  status: "idle" | "downloading" | "installing" | "rebooting" | "error";
  message?: string;
  version?: string;
  size?: string;
}

export interface UseSoftwareUpdateReturn {
  updateInfo: UpdateInfo | null;
  updateStatus: UpdateStatus;
  downloadState: DownloadState | null;
  isLoading: boolean;
  isChecking: boolean;
  isUpdating: boolean;
  isDownloading: boolean;
  error: string | null;
  lastChecked: string | null;
  checkForUpdates: () => Promise<void>;
  downloadUpdate: (version?: string) => Promise<void>;
  installStaged: () => Promise<void>;
  installUpdate: () => Promise<void>;
  installVersion: (version: string) => Promise<void>;
  togglePrerelease: (enabled: boolean) => Promise<void>;
  /** Resolves to the response body on success, `false` when the save failed. */
  saveAutoUpdate: (
    enabled: boolean,
    time: string,
  ) => Promise<CgiJson | false>;
}

// ─── Hook ───────────────────────────────────────────────────────────────────

export function useSoftwareUpdate(): UseSoftwareUpdateReturn {
  const [updateInfo, setUpdateInfo] = useState<UpdateInfo | null>(null);
  const [updateStatus, setUpdateStatus] = useState<UpdateStatus>({ status: "idle" });
  const [isLoading, setIsLoading] = useState(true);
  const [isChecking, setIsChecking] = useState(false);
  const [isUpdating, setIsUpdating] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [downloadState, setDownloadState] = useState<DownloadState | null>(null);
  const [isDownloading, setIsDownloading] = useState(false);
  const [lastChecked, setLastChecked] = useState<string | null>(null);

  const mountedRef = useRef(true);
  const pollRef = useRef<ReturnType<typeof setInterval> | null>(null);
  /**
   * Which flow owns pollRef. All three pollers share the one interval slot, and
   * they do not understand each other's statuses — see startDownloadPolling.
   */
  const pollOwnerRef = useRef<"download" | "install" | null>(null);

  const stopPolling = useCallback(() => {
    if (pollRef.current) clearInterval(pollRef.current);
    pollRef.current = null;
    pollOwnerRef.current = null;
  }, []);

  /**
   * POST an action to update.sh and hand back the parsed reply, throwing a
   * message worth showing if there isn't one.
   *
   * The raw .json() call these replaced would surface "Unexpected token '<'"
   * whenever a CGI died before emitting its headers and lighttpd substituted an
   * HTML error page — true, and useless to whoever is reading the screen.
   */
  const postAction = useCallback(
    async (body: Record<string, unknown>): Promise<CgiJson> => {
      const resp = await authFetch(CGI_ENDPOINT, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });

      const json = await readJson(resp);
      if (!json) {
        throw new Error(
          resp.ok
            ? "The device returned an unreadable response."
            : `HTTP ${resp.status}: ${resp.statusText}`,
        );
      }
      return json;
    },
    [],
  );

  useEffect(() => {
    mountedRef.current = true;
    // Load last checked from localStorage.
    //
    // A bare localStorage.getItem here threw SecurityError in any storage-blocked
    // document, and a throw in an effect body is not contained — React unmounts
    // the tree, so the System Update page went blank over a cosmetic timestamp.
    //
    // This stays an effect rather than becoming a lazy useState initializer, and
    // that is deliberate: QManager is a static export, so every page load is a
    // hydration of HTML built on a machine that never saw this browser's storage.
    // Reading the value during the hydration render would make the client's first
    // paint disagree with the prerendered markup. Reading it after commit is the
    // one placement that is honest about where the value comes from.
    const stored = readStorageValueOrNull("local", LAST_CHECKED_KEY);
    if (stored) setLastChecked(stored);
    return () => {
      mountedRef.current = false;
      stopPolling();
    };
  }, [stopPolling]);

  // ---------------------------------------------------------------------------
  // Poll download status during background download
  // ---------------------------------------------------------------------------
  const startDownloadPolling = useCallback(() => {
    // Never displace an install poller. fetchUpdateInfo restarts download
    // polling whenever the backend reports a download in flight, so any caller
    // of it (checkForUpdates, togglePrerelease, saveAutoUpdate) would otherwise
    // swap the install poller — which watches for installing/rebooting — for
    // this one, which only knows ready/error. The install would then never be
    // seen to finish: isUpdating stays true, and software-update.tsx renders
    // the full-screen stepper for as long as it is, leaving no control on
    // screen to recover with.
    if (pollOwnerRef.current === "install") return;

    stopPolling();
    pollOwnerRef.current = "download";

    pollRef.current = setInterval(async () => {
      let resp: Response;
      try {
        resp = await authFetch(`${CGI_ENDPOINT}?action=status`);
      } catch {
        return; // Blink — retry on the next interval.
      }

      if (isSessionRedirectInFlight()) {
        stopPolling();
        return;
      }
      if (!resp.ok) return;

      const json = await readJson(resp);
      if (!json?.status || !mountedRef.current) return;

      // Only the four states this card can draw. The status file is shared with
      // the install flow and also carries "installing"/"rebooting"/"starting";
      // writing those into DownloadState would put a value in the field that no
      // branch of the card matches, blanking the progress row mid-download.
      if (
        json.status === "downloading" ||
        json.status === "verifying" ||
        json.status === "ready" ||
        json.status === "error"
      ) {
        setDownloadState({
          status: json.status,
          version: json.version ?? "",
          message: json.message,
          size: json.size,
        });
      }

      if (json.status === "ready") {
        stopPolling();
        setIsDownloading(false);
      }

      if (json.status === "error") {
        stopPolling();
        setIsDownloading(false);
        setError(json.message || "Download failed");
      }
    }, POLL_INTERVAL);
  }, [stopPolling]);

  // ---------------------------------------------------------------------------
  // Fetch update info from CGI
  // ---------------------------------------------------------------------------
  const fetchUpdateInfo = useCallback(async (silent = false) => {
    if (!silent) setIsLoading(true);
    setError(null);

    try {
      const resp = await authFetch(CGI_ENDPOINT);
      if (!resp.ok) throw new Error(`HTTP ${resp.status}: ${resp.statusText}`);

      const json = await readJson(resp);
      if (!json) throw new Error("The device returned an unreadable response.");
      if (!mountedRef.current) return;

      if (!json.success) {
        setError(json.detail || json.error || "Failed to check for updates");
        return;
      }

      setUpdateInfo(json as UpdateInfo);

      // Sync download state from backend
      const info = json as UpdateInfo;
      if (info.download_state) {
        setDownloadState(info.download_state);
        if (info.download_state.status === "downloading" || info.download_state.status === "verifying") {
          setIsDownloading(true);
          startDownloadPolling();
        }
      }

      // Update last checked timestamp.
      //
      // The bare setItem this replaces sat inside the same try/catch as the
      // fetch, so a QuotaExceededError or a blocked store was reported to the
      // user as "Failed to check for updates" — for a check that had already
      // succeeded — and skipped the setLastChecked below with it. The write can
      // no longer throw, so the catch is left to the network errors it was
      // written for, and a store we cannot persist to now costs only the
      // remembered timestamp across reloads.
      const now = new Date().toISOString();
      writeStorageValue("local", LAST_CHECKED_KEY, now);
      setLastChecked(now);
    } catch (err) {
      if (!mountedRef.current) return;
      setError(err instanceof Error ? err.message : "Failed to check for updates");
    } finally {
      if (mountedRef.current && !silent) setIsLoading(false);
    }
  }, [startDownloadPolling]);

  // Fetch on mount
  useEffect(() => {
    fetchUpdateInfo();
  }, [fetchUpdateInfo]);

  // ---------------------------------------------------------------------------
  // Poll update status during install/rollback
  // ---------------------------------------------------------------------------
  const startPolling = useCallback(() => {
    stopPolling();
    pollOwnerRef.current = "install";

    let networkStrikes = 0;
    let lastSignature = "";
    let lastChangeAt = Date.now();
    let stallReported = false;

    const goToRebootPage = () => {
      // Navigate to /reboot/ so the static page is in browser memory before the
      // OTA worker fires the reboot syscall — the worker waits for that page's
      // reboot_ack, so getting there promptly is what keeps the handoff clean.
      stopPolling();
      handOffToRebootPage();
    };

    pollRef.current = setInterval(async () => {
      let resp: Response;
      try {
        resp = await authFetch(`${CGI_ENDPOINT}?action=status`);
      } catch {
        // Only a rejected fetch suggests the device went away, and even that is
        // ambiguous — see REBOOT_INFERENCE_STRIKES.
        networkStrikes += 1;
        if (networkStrikes >= REBOOT_INFERENCE_STRIKES) goToRebootPage();
        return;
      }

      networkStrikes = 0;

      if (isSessionRedirectInFlight()) {
        stopPolling();
        return;
      }
      if (!resp.ok) return;

      // A 200 we cannot parse means lighttpd is up and the CGI is broken — the
      // opposite of a reboot. Fall through to the next tick, never navigate.
      const json = await readJson(resp);
      if (!json?.status || !mountedRef.current) return;

      const signature = `${json.status}|${json.message ?? ""}`;
      if (signature !== lastSignature) {
        lastSignature = signature;
        lastChangeAt = Date.now();
      } else if (
        !stallReported &&
        Date.now() - lastChangeAt >= STALL_TIMEOUT_MS
      ) {
        // The worker can die without ever writing status:"error" — an OOM kill
        // on this box takes the whole sudo child with it — and the status file
        // it leaves behind still reads "installing". Nothing in the reply lets
        // the browser tell that apart from a live install, so elapsed silence
        // is the only signal available. Release the UI lock (the full-screen
        // stepper is modal: while isUpdating is true there is no control left
        // to press) but keep polling, so a merely slow install still gets its
        // "rebooting" handled below.
        stallReported = true;
        setIsUpdating(false);
        setError(
          "No progress reported for 10 minutes. The install may still be running — reload this page after the device reboots.",
        );
      }

      setUpdateStatus(toUpdateStatus(json));

      if (json.status === "rebooting") {
        goToRebootPage();
        return;
      }

      if (json.status === "error") {
        stopPolling();
        setIsUpdating(false);
        setError(json.message || "Update failed");
      }
    }, POLL_INTERVAL);
  }, [stopPolling]);

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------
  const checkForUpdates = useCallback(async () => {
    setIsChecking(true);
    await fetchUpdateInfo(true);
    if (mountedRef.current) setIsChecking(false);
  }, [fetchUpdateInfo]);

  const downloadUpdate = useCallback(async (version?: string) => {
    const targetVersion = version || updateInfo?.latest_version;
    if (!targetVersion) return;

    setError(null);
    setIsDownloading(true);
    setDownloadState({ status: "downloading", version: targetVersion });

    try {
      const json = await postAction({
        action: "download",
        version: targetVersion,
      });
      if (!json.success) {
        setError(json.detail || json.error || "Failed to start download");
        setIsDownloading(false);
        setDownloadState(null);
        return;
      }

      startDownloadPolling();
    } catch (err) {
      if (!mountedRef.current) return;
      setError(err instanceof Error ? err.message : "Failed to start download");
      setIsDownloading(false);
      setDownloadState(null);
    }
  }, [updateInfo, startDownloadPolling, postAction]);

  const installStaged = useCallback(async () => {
    setError(null);
    setIsUpdating(true);
    setUpdateStatus({ status: "installing", message: "Installing update..." });

    try {
      const json = await postAction({ action: "install_staged" });
      if (!json.success) {
        setError(json.detail || json.error || "Failed to start installation");
        setIsUpdating(false);
        return;
      }

      startPolling();
    } catch (err) {
      if (!mountedRef.current) return;
      setError(err instanceof Error ? err.message : "Failed to start installation");
      setIsUpdating(false);
    }
  }, [startPolling, postAction]);

  // ---------------------------------------------------------------------------
  // Chained poller — used by installVersion to fuse the two-step flow into one
  // click. Both phases write to the same /tmp/qmanager_update.json, so a single
  // setInterval can watch the download phase, fire install_staged once it sees
  // status:"ready", then keep polling through installing → rebooting.
  // ---------------------------------------------------------------------------
  const startChainedPolling = useCallback((version: string) => {
    stopPolling();
    pollOwnerRef.current = "install";

    let installPosted = false;
    /** Has the download we just started taken ownership of the status file? */
    let workerSeen = false;
    let staleReadyTicks = 0;
    let networkStrikes = 0;
    let lastSignature = "";
    let lastChangeAt = Date.now();
    let stallReported = false;

    const goToRebootPage = () => {
      stopPolling();
      handOffToRebootPage();
    };

    const failWith = (message: string) => {
      stopPolling();
      setIsUpdating(false);
      setError(message);
    };

    pollRef.current = setInterval(async () => {
      let resp: Response;
      try {
        resp = await authFetch(`${CGI_ENDPOINT}?action=status`);
      } catch {
        networkStrikes += 1;
        // Before install_staged is posted there is nothing to reboot for, so a
        // dead device just means the download never finishes — keep polling
        // rather than sending the user to a countdown for a reboot no one
        // asked for.
        if (installPosted && networkStrikes >= REBOOT_INFERENCE_STRIKES) {
          goToRebootPage();
        }
        return;
      }

      networkStrikes = 0;

      if (isSessionRedirectInFlight()) {
        stopPolling();
        return;
      }
      if (!resp.ok) return;

      const json = await readJson(resp);
      if (!json?.status || !mountedRef.current) return;

      const raw = json.status;

      // ── Stale-"ready" guard ──────────────────────────────────────────────
      // update.sh answers action=download the instant it has double-forked the
      // worker through sudo, before that worker has written its first status.
      // For the first tick or two the status file therefore still holds the
      // PREVIOUS run's terminal state. Chaining off that posts install_staged
      // against whatever tarball happens to be staged — installing a version
      // the user did not pick, or (once the real worker claims the PID lock)
      // failing with "An update is already in progress" while the download it
      // is complaining about carries on invisibly.
      //
      // So: only act on "ready" once this run is accounted for. Normally that
      // is the worker moving the file to downloading/verifying. The fallback
      // covers a download that finished inside a single poll interval — a
      // "ready" that persists for STALE_READY_TICKS with no worker in sight and
      // names the version we asked for is staged and safe to install.
      if (raw === "downloading" || raw === "verifying") {
        workerSeen = true;
      } else if (raw === "ready" && !workerSeen) {
        staleReadyTicks += 1;
        if (staleReadyTicks >= STALE_READY_TICKS && json.version === version) {
          workerSeen = true;
        }
      }

      const signature = `${raw}|${json.message ?? ""}`;
      if (signature !== lastSignature) {
        lastSignature = signature;
        lastChangeAt = Date.now();
      } else if (
        !stallReported &&
        Date.now() - lastChangeAt >= STALL_TIMEOUT_MS
      ) {
        // See startPolling — same dead-worker case, same reason for keeping the
        // poll alive while releasing the modal stepper.
        stallReported = true;
        setIsUpdating(false);
        setError(
          "No progress reported for 10 minutes. The install may still be running — reload this page after the device reboots.",
        );
      }

      // Download sub-phases collapse to step 0; once install_staged is posted
      // the next tick reports "installing" and the stepper advances.
      if (raw === "downloading" || raw === "verifying") {
        setUpdateStatus({
          status: "downloading",
          message: json.message,
          version,
          size: json.size,
        });
      } else if (raw === "installing" || raw === "rebooting" || raw === "error") {
        setUpdateStatus(toUpdateStatus(json, version));
      }

      // Chain step: when the download reports ready, fire install_staged once.
      if (raw === "ready" && workerSeen && !installPosted) {
        installPosted = true;
        setUpdateStatus({
          status: "installing",
          message: "Installing update...",
          version,
        });
        try {
          const installJson = await postAction({ action: "install_staged" });
          if (!installJson.success) {
            installPosted = false;
            failWith(
              installJson.detail ||
                installJson.error ||
                "Failed to start installation",
            );
          }
        } catch (err) {
          installPosted = false;
          failWith(
            err instanceof Error ? err.message : "Failed to start installation",
          );
        }
        return;
      }

      if (raw === "rebooting") {
        goToRebootPage();
        return;
      }

      if (raw === "error") {
        failWith(json.message || "Install failed");
      }
    }, POLL_INTERVAL);
  }, [postAction, stopPolling]);

  // ---------------------------------------------------------------------------
  // installVersion — one-click chained install for a specific version. Used by
  // Version Management. Backend uses the same two endpoints as the main flow
  // (download → install_staged); the chain happens in the poller above.
  // ---------------------------------------------------------------------------
  const installVersion = useCallback(async (version: string) => {
    if (!version) return;

    setError(null);
    setIsUpdating(true);
    setUpdateStatus({ status: "downloading", version });

    try {
      const json = await postAction({ action: "download", version });
      if (!json.success) {
        setError(json.detail || json.error || "Failed to start install");
        setIsUpdating(false);
        return;
      }

      startChainedPolling(version);
    } catch (err) {
      if (!mountedRef.current) return;
      setError(err instanceof Error ? err.message : "Failed to start install");
      setIsUpdating(false);
    }
  }, [startChainedPolling, postAction]);

  const installUpdate = useCallback(async () => {
    if (!updateInfo?.download_url || !updateInfo?.latest_version) return;

    setError(null);
    setIsUpdating(true);
    setUpdateStatus({ status: "downloading", version: updateInfo.latest_version });

    try {
      const json = await postAction({
        action: "install",
        download_url: updateInfo.download_url,
        version: updateInfo.latest_version,
        download_size: updateInfo.download_size,
      });
      if (!json.success) {
        setError(json.detail || json.error || "Failed to start update");
        setIsUpdating(false);
        return;
      }

      startPolling();
    } catch (err) {
      if (!mountedRef.current) return;
      setError(err instanceof Error ? err.message : "Failed to start update");
      setIsUpdating(false);
    }
  }, [updateInfo, startPolling, postAction]);

  const togglePrerelease = useCallback(async (enabled: boolean) => {
    try {
      const json = await postAction({ action: "save_prerelease", enabled });
      if (!json.success) {
        setError(json.detail || json.error || "Failed to save preference");
        return;
      }

      // Re-check with new preference
      await fetchUpdateInfo(true);
    } catch (err) {
      if (!mountedRef.current) return;
      setError(err instanceof Error ? err.message : "Failed to save preference");
    }
  }, [fetchUpdateInfo, postAction]);

  // Resolves to the response body on success and `false` on failure, so the
  // card can tell "saved" from "scheduled". The backend answers
  // schedule_armed:false when the config write succeeded but the systemd timer
  // could not be armed; swallowing that here is what left the auto-update
  // toggle green while nothing was scheduled.
  const saveAutoUpdate = useCallback(async (enabled: boolean, time: string) => {
    try {
      const json = await postAction({ action: "save_auto_update", enabled, time });
      if (!json.success) {
        setError(json.detail || json.error || "Failed to save auto-update preference");
        return false as const;
      }

      await fetchUpdateInfo(true);
      return json;
    } catch (err) {
      if (!mountedRef.current) return false as const;
      setError(err instanceof Error ? err.message : "Failed to save auto-update preference");
      return false as const;
    }
  }, [fetchUpdateInfo, postAction]);

  return {
    updateInfo,
    updateStatus,
    downloadState,
    isLoading,
    isChecking,
    isUpdating,
    isDownloading,
    error,
    lastChecked,
    checkForUpdates,
    downloadUpdate,
    installStaged,
    installUpdate,
    installVersion,
    togglePrerelease,
    saveAutoUpdate,
  };
}
