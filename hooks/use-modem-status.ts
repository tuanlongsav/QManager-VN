"use client";

import { useState, useEffect, useCallback } from "react";
import { authFetch } from "@/lib/auth-fetch";
import type { ModemStatus } from "@/types/modem-status";

// =============================================================================
// useModemStatus — SHARED polling hook for the QManager dashboard
// =============================================================================
// Every consumer reads the same cached CGI endpoint (the poller writes
// /tmp/qmanager_status.json; this endpoint just `cat`s it). Previously each
// component mounted its OWN interval + fetch, so a single page could fire 2-3
// duplicate polls of the same file every 2s — and each poll makes lighttpd
// fork a bash CGI process on a single-core ARMv7 modem.
//
// This hook now routes all consumers through ONE module-level poller that:
//   • runs a single interval at the smallest rate any subscriber requests,
//   • dedupes in-flight requests (no pile-up if the device is briefly slow),
//   • PAUSES entirely while the browser tab is hidden, so a backgrounded or
//     locked phone stops forking CGI processes on the modem.
//
// The hook never touches the modem — it only reads the pre-built JSON cache.
// The public API (data/isLoading/isStale/error/refresh) is unchanged.
// =============================================================================

/** How often to poll the CGI endpoint (ms) */
const DEFAULT_POLL_INTERVAL = 2000;

/** After this many seconds without a fresh timestamp, data is "stale" */
const STALE_THRESHOLD_SECONDS = 10;

/** CGI endpoint path (proxied in dev via next.config.ts rewrites) */
const FETCH_ENDPOINT = "/cgi-bin/quecmanager/at_cmd/fetch_data.sh";

export interface UseModemStatusOptions {
  /** Polling interval in ms (default: 2000) */
  pollInterval?: number;
  /** Whether polling is active (default: true) */
  enabled?: boolean;
}

export interface UseModemStatusReturn {
  /** The latest modem status data (null before first successful fetch) */
  data: ModemStatus | null;
  /** True during the very first fetch (before any data is available) */
  isLoading: boolean;
  /** True if the data's timestamp is older than the stale threshold */
  isStale: boolean;
  /** Error message if the last fetch failed */
  error: string | null;
  /** Manually trigger an immediate refresh */
  refresh: () => void;
}

// --- Module-level shared poller ----------------------------------------------

interface SharedSnapshot {
  data: ModemStatus | null;
  isLoading: boolean;
  isStale: boolean;
  error: string | null;
}

type Listener = (snap: SharedSnapshot) => void;

const snapshot: SharedSnapshot = {
  data: null,
  isLoading: true,
  isStale: false,
  error: null,
};

/** listener -> the poll interval (ms) that subscriber asked for */
const subscribers = new Map<Listener, number>();
let timer: ReturnType<typeof setInterval> | null = null;
let activeIntervalMs = 0;
let inFlight = false;
let visibilityHooked = false;

function emit() {
  // Fresh object so React sees a new reference and re-renders.
  const snap: SharedSnapshot = { ...snapshot };
  subscribers.forEach((_interval, listener) => listener(snap));
}

async function fetchOnce() {
  if (inFlight) return; // dedupe: skip if a request is still pending
  inFlight = true;
  try {
    const response = await authFetch(FETCH_ENDPOINT);
    if (!response.ok) {
      throw new Error(`HTTP ${response.status}: ${response.statusText}`);
    }
    const json: ModemStatus = await response.json();
    snapshot.data = json;
    snapshot.error = null;
    const now = Math.floor(Date.now() / 1000);
    snapshot.isStale = now - json.timestamp > STALE_THRESHOLD_SECONDS;
    snapshot.isLoading = false;
  } catch (err) {
    // Keep the last data on error — show it stale with an error indicator.
    snapshot.error =
      err instanceof Error ? err.message : "Failed to fetch modem status";
    snapshot.isStale = true;
    snapshot.isLoading = false;
  } finally {
    inFlight = false;
    emit();
  }
}

function minInterval(): number {
  let m = Infinity;
  subscribers.forEach((interval) => {
    if (interval < m) m = interval;
  });
  return m === Infinity ? DEFAULT_POLL_INTERVAL : m;
}

function startTimer() {
  // Paused while the tab is hidden — onVisibilityChange restarts it.
  if (typeof document !== "undefined" && document.hidden) return;
  const ms = minInterval();
  if (timer && activeIntervalMs === ms) return; // already at the right rate
  if (timer) clearInterval(timer);
  activeIntervalMs = ms;
  timer = setInterval(fetchOnce, ms);
}

function stopTimer() {
  if (timer) {
    clearInterval(timer);
    timer = null;
  }
  activeIntervalMs = 0;
}

function onVisibilityChange() {
  if (document.hidden) {
    stopTimer(); // stop forking CGI while backgrounded
  } else if (subscribers.size > 0) {
    fetchOnce(); // catch up immediately on return
    startTimer();
  }
}

function ensureVisibilityHook() {
  if (visibilityHooked || typeof document === "undefined") return;
  document.addEventListener("visibilitychange", onVisibilityChange);
  visibilityHooked = true;
}

function subscribe(listener: Listener, intervalMs: number): () => void {
  const firstEver = subscribers.size === 0;
  subscribers.set(listener, intervalMs);
  ensureVisibilityHook();
  // Hand the new subscriber the current snapshot immediately.
  listener({ ...snapshot });
  if (firstEver) {
    fetchOnce(); // immediate first load
  }
  startTimer(); // (re)start — interval may now be smaller
  return () => {
    subscribers.delete(listener);
    if (subscribers.size === 0) {
      stopTimer();
    } else {
      startTimer(); // interval may grow if the fastest consumer left
    }
  };
}

export function useModemStatus(
  options: UseModemStatusOptions = {}
): UseModemStatusReturn {
  const { pollInterval = DEFAULT_POLL_INTERVAL, enabled = true } = options;

  const [snap, setSnap] = useState<SharedSnapshot>(snapshot);

  useEffect(() => {
    if (!enabled) return;
    // setSnap has a stable identity, so it's a valid Map key/listener.
    return subscribe(setSnap, pollInterval);
  }, [enabled, pollInterval]);

  const refresh = useCallback(() => {
    fetchOnce();
  }, []);

  return {
    data: snap.data,
    isLoading: snap.isLoading,
    isStale: snap.isStale,
    error: snap.error,
    refresh,
  };
}
