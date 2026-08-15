"use client";

import { useState, useEffect, useCallback, useRef } from "react";
import { authFetch } from "@/lib/auth-fetch";
import type {
  BandCategory,
  CurrentBands,
  FailoverState,
  BandCurrentResponse,
  BandLockResponse,
  FailoverToggleResponse,
  FailoverStatusResponse,
} from "@/types/band-locking";
import { bandArrayToString } from "@/types/band-locking";

// =============================================================================
// useBandLocking — Band Lock State, Lock/Unlock, & Failover Hook
// =============================================================================
// Manages the band locking lifecycle: fetching current locked bands,
// applying per-category band locks, unlocking all bands, and toggling
// the failover safety mechanism.
//
// After a successful band lock (when failover is enabled), the hook polls
// the lightweight failover_status.sh endpoint every 1s until the watcher
// process completes. This detects whether failover activated and updates
// the UI accordingly — without touching the modem.
//
// Backend endpoints:
//   GET  /cgi-bin/quecmanager/bands/current.sh           → locked bands + failover
//   GET  /cgi-bin/quecmanager/bands/failover_status.sh   → lightweight flag check
//   POST /cgi-bin/quecmanager/bands/lock.sh              → apply band lock
//   POST /cgi-bin/quecmanager/bands/failover_toggle.sh   → enable/disable failover
// =============================================================================

const CGI_BASE = "/cgi-bin/quecmanager/bands";
const FAILOVER_POLL_INTERVAL = 1000; // 1s — watcher sleeps 5s then checks

// ---------------------------------------------------------------------------
// Wire normalisation
// ---------------------------------------------------------------------------
//
// Read this before adding another `const data: SomeResponse = await resp.json()`
// to this file: that annotation is a CLAIM, not a check. `Response.json()` is
// typed `Promise<any>`, so the type name on the left buys nothing at runtime —
// TypeScript erases it, and whatever the device actually sent is stored as-is.
//
// That is not theoretical here. `setFailover(data.failover)` used to run on any
// reply with `success: true`, and band-settings.tsx then read `failover.enabled`
// during render. A 200 that omitted the `failover` object therefore threw
// "Cannot read properties of undefined" out of a render pass — and because
// BandSettingsComponent is mounted by components/dashboard/home-component.tsx,
// that took down the entire dashboard, not just this card. On a headless modem
// whose only UI is this page, that is the difference between a wrong badge and a
// box that needs SSH.
//
// A reply can lose a field without being "corrupt": the /www tree is swapped
// wholesale during an OTA, so a browser tab held open across an update can talk
// to a CGI from one version while running the JS of another. Field-by-field
// normalisation is what makes that survivable.

/**
 * Coerce one wire field into a boolean.
 *
 * NOT `Boolean(value)`: the backend is shell, and the string "false" is what a
 * shell writes when jq's `--argjson` is not in play — `Boolean("false")` is
 * `true`, which would report failover as armed precisely when it is not. So the
 * spellings are matched explicitly and everything unrecognised (including a
 * missing field) reads as `false`.
 *
 * `false` is the safe default for all three failover flags: "not enabled", "has
 * not fired", "not monitoring". Nothing destructive follows from any of them, so
 * a gap degrades to a conservative badge rather than to an exception.
 */
function toBool(value: unknown): boolean {
  if (typeof value === "boolean") return value;
  if (typeof value === "number") return value !== 0;
  if (typeof value === "string") return value === "true" || value === "1";
  return false;
}

/**
 * Build a complete FailoverState out of whatever arrived.
 *
 * Deliberately total — it always returns a usable object rather than `null` for
 * a malformed input, which is the opposite of toCurrentBands below, and the
 * asymmetry is the point. Refusing the payload outright would also discard
 * `current`, the band lists that are the only reason this page loads, so one
 * missing failover flag would blank all three band cards. Filling the gap costs
 * a possibly-stale badge; refusing costs the page.
 *
 * Accepts `unknown` so it can normalise both shapes that carry these flags: the
 * nested `failover` object from current.sh and the flat body of
 * failover_status.sh.
 */
function toFailoverState(value: unknown): FailoverState {
  // A primitive here yields `undefined` for every lookup, which toBool already
  // maps to false — so no shape check is needed, only a null guard.
  const raw = (value ?? {}) as Partial<Record<keyof FailoverState, unknown>>;
  return {
    enabled: toBool(raw.enabled),
    activated: toBool(raw.activated),
    watcher_running: toBool(raw.watcher_running),
  };
}

/**
 * Narrow the `current` object, or report that there wasn't one.
 *
 * `null` rather than a synthetic empty object because the declared state type is
 * `CurrentBands | null` and the consumers already branch on it —
 * band-locking.tsx renders empty band cards for `null`. Storing `undefined`, as
 * the unchecked assignment did, was a value the type does not admit; it happened
 * to render the same way, which is exactly why it would have gone unnoticed
 * until some later consumer treated `null` and `undefined` differently.
 */
function toCurrentBands(value: unknown): CurrentBands | null {
  if (!value || typeof value !== "object") return null;
  const raw = value as Partial<Record<keyof CurrentBands, unknown>>;
  const str = (v: unknown) => (typeof v === "string" ? v : "");
  return {
    lte_bands: str(raw.lte_bands),
    nsa_nr5g_bands: str(raw.nsa_nr5g_bands),
    sa_nr5g_bands: str(raw.sa_nr5g_bands),
  };
}

export interface UseBandLockingReturn {
  /** Currently locked/configured bands from ue_capability_band */
  currentBands: CurrentBands | null;
  /** Failover safety mechanism state */
  failover: FailoverState;
  /** True during initial data fetch */
  isLoading: boolean;
  /** Which band category is currently being locked/unlocked (null = idle) */
  lockingCategory: BandCategory | null;
  /** Error message from the last operation */
  error: string | null;
  /**
   * Lock specific bands for one category.
   * Sends AT+QNWPREFCFG command for the specified band type.
   * Re-fetches current bands on success.
   * @returns success boolean
   */
  lockBands: (category: BandCategory, bands: number[]) => Promise<boolean>;
  /**
   * Unlock all bands for one category by setting to full supported list.
   * Requires the supported band list (from useModemStatus) to be passed in.
   * @returns success boolean
   */
  unlockAll: (
    category: BandCategory,
    supportedBands: number[],
  ) => Promise<boolean>;
  /**
   * Toggle the failover safety mechanism on/off.
   * @returns success boolean
   */
  toggleFailover: (enabled: boolean) => Promise<boolean>;
  /** Manually refresh current bands + failover state */
  refresh: () => void;
}

export function useBandLocking(): UseBandLockingReturn {
  const [currentBands, setCurrentBands] = useState<CurrentBands | null>(null);
  const [failover, setFailover] = useState<FailoverState>({
    enabled: false,
    activated: false,
    watcher_running: false,
  });
  const [isLoading, setIsLoading] = useState(true);
  const [lockingCategory, setLockingCategory] = useState<BandCategory | null>(
    null,
  );
  const [error, setError] = useState<string | null>(null);

  const mountedRef = useRef(true);
  const failoverPollRef = useRef<ReturnType<typeof setInterval> | null>(null);

  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
      // Clean up any running failover poll on unmount
      if (failoverPollRef.current) {
        clearInterval(failoverPollRef.current);
        failoverPollRef.current = null;
      }
    };
  }, []);

  // ---------------------------------------------------------------------------
  // Fetch current locked bands + failover state (full — touches modem)
  // ---------------------------------------------------------------------------
  const fetchCurrent = useCallback(async () => {
    try {
      const resp = await authFetch(`${CGI_BASE}/current.sh?_t=${Date.now()}`);
      if (!resp.ok) {
        throw new Error(`HTTP ${resp.status}: ${resp.statusText}`);
      }

      // Partial<> is the honest annotation: every field here crossed a network
      // from a shell script, so none of them is guaranteed to have arrived.
      const data: Partial<BandCurrentResponse> | null = await resp.json();
      if (!mountedRef.current) return;

      if (!data?.success) {
        setError(
          data?.detail || data?.error || "Failed to fetch band configuration",
        );
        return;
      }

      setCurrentBands(toCurrentBands(data.current));
      setFailover(toFailoverState(data.failover));
      setError(null);
    } catch (err) {
      if (!mountedRef.current) return;
      setError(
        err instanceof Error
          ? err.message
          : "Failed to fetch band configuration",
      );
    } finally {
      if (mountedRef.current) {
        setIsLoading(false);
      }
    }
  }, []);

  // Initial fetch
  useEffect(() => {
    fetchCurrent();
  }, [fetchCurrent]);

  // ---------------------------------------------------------------------------
  // Failover status polling (lightweight — no modem contact)
  // ---------------------------------------------------------------------------
  // Started after a successful band lock when failover is enabled.
  // Polls failover_status.sh until the watcher process exits, then:
  //   - Updates failover state from the response
  //   - If activated → re-fetches current.sh to get the reset bands
  //   - Stops polling
  // ---------------------------------------------------------------------------
  const startFailoverPolling = useCallback(() => {
    // Clear any existing poll
    if (failoverPollRef.current) {
      clearInterval(failoverPollRef.current);
      failoverPollRef.current = null;
    }

    failoverPollRef.current = setInterval(async () => {
      if (!mountedRef.current) {
        if (failoverPollRef.current) {
          clearInterval(failoverPollRef.current);
          failoverPollRef.current = null;
        }
        return;
      }

      try {
        const resp = await authFetch(`${CGI_BASE}/failover_status.sh`);
        if (!resp.ok) return; // Silent fail — retry next interval

        const data: Partial<FailoverStatusResponse> | null = await resp.json();
        if (!mountedRef.current) return;

        // failover_status.sh has no `success` envelope — its whole body IS the
        // three flags, so the body is what gets normalised. Doing it once here
        // also removes the three separate `data.<flag>` reads that previously
        // wrote raw wire values straight into state.
        //
        // A reply missing `watcher_running` therefore reads as "finished" and
        // ends the poll. That is the deliberate direction: an unbounded 1s poll
        // against a device whose CGI is answering nonsense is worse than a badge
        // that stops at "Ready" one tick early, and the next fetchCurrent() or
        // page load re-reads the real state anyway.
        const next = toFailoverState(data);

        // Watcher still running — update state to show "Monitoring", keep polling
        if (next.watcher_running) {
          setFailover(next);
          return;
        }

        // Watcher finished — stop polling and update state
        if (failoverPollRef.current) {
          clearInterval(failoverPollRef.current);
          failoverPollRef.current = null;
        }

        setFailover(next);

        // If failover activated, bands were reset — re-fetch to get new values
        if (next.activated) {
          await fetchCurrent();
        }
      } catch {
        // Network error — silent, retry next interval
      }
    }, FAILOVER_POLL_INTERVAL);
  }, [fetchCurrent]);

  // ---------------------------------------------------------------------------
  // Lock bands for one category
  // ---------------------------------------------------------------------------
  const lockBands = useCallback(
    async (category: BandCategory, bands: number[]): Promise<boolean> => {
      if (bands.length === 0) {
        setError("No bands selected");
        return false;
      }

      setError(null);
      setLockingCategory(category);

      try {
        const resp = await authFetch(`${CGI_BASE}/lock.sh`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            band_type: category,
            bands: bandArrayToString(bands),
          }),
        });

        if (!resp.ok) {
          throw new Error(`HTTP ${resp.status}: ${resp.statusText}`);
        }

        const data: Partial<BandLockResponse> | null = await resp.json();
        if (!mountedRef.current) return false;

        if (!data?.success) {
          setError(data?.detail || data?.error || "Failed to apply band lock");
          return false;
        }

        // Re-fetch current state to confirm the lock took effect
        await fetchCurrent();

        // If failover is armed (enabled + watcher spawned), start polling
        // for watcher completion so we detect activation in real-time
        if (toBool(data.failover_armed)) {
          // Clear any previous activated flag from UI — watcher just started fresh
          setFailover((prev) => ({ ...prev, activated: false }));
          startFailoverPolling();
        }

        return true;
      } catch (err) {
        if (!mountedRef.current) return false;
        setError(
          err instanceof Error ? err.message : "Failed to apply band lock",
        );
        return false;
      } finally {
        if (mountedRef.current) {
          setLockingCategory(null);
        }
      }
    },
    [fetchCurrent, startFailoverPolling],
  );

  // ---------------------------------------------------------------------------
  // Unlock all bands for one category (set to full supported list)
  // ---------------------------------------------------------------------------
  const unlockAll = useCallback(
    async (
      category: BandCategory,
      supportedBands: number[],
    ): Promise<boolean> => {
      if (supportedBands.length === 0) {
        setError("Supported bands not available");
        return false;
      }

      // Locking to ALL supported bands = unlock all
      return lockBands(category, supportedBands);
    },
    [lockBands],
  );

  // ---------------------------------------------------------------------------
  // Toggle failover
  // ---------------------------------------------------------------------------
  const toggleFailover = useCallback(
    async (enabled: boolean): Promise<boolean> => {
      setError(null);

      try {
        const resp = await authFetch(`${CGI_BASE}/failover_toggle.sh`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ enabled }),
        });

        if (!resp.ok) {
          throw new Error(`HTTP ${resp.status}: ${resp.statusText}`);
        }

        const data: Partial<FailoverToggleResponse> | null = await resp.json();
        if (!mountedRef.current) return false;

        if (!data?.success) {
          setError(data?.detail || data?.error || "Failed to toggle failover");
          return false;
        }

        // Optimistic update. An echoed `enabled` is authoritative; an absent one
        // falls back to what the user just asked for, which is what the `??`
        // here always did — toBool only stops a stringly-typed echo ("false")
        // from flipping the switch the wrong way.
        setFailover((prev) => ({
          ...prev,
          enabled: data.enabled == null ? enabled : toBool(data.enabled),
        }));
        return true;
      } catch (err) {
        if (!mountedRef.current) return false;
        setError(
          err instanceof Error ? err.message : "Failed to toggle failover",
        );
        return false;
      }
    },
    [],
  );

  // ---------------------------------------------------------------------------
  // Manual refresh
  // ---------------------------------------------------------------------------
  const refresh = useCallback(() => {
    setIsLoading(true);
    fetchCurrent();
  }, [fetchCurrent]);

  return {
    currentBands,
    failover,
    isLoading,
    lockingCategory,
    error,
    lockBands,
    unlockAll,
    toggleFailover,
    refresh,
  };
}
