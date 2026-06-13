"use client";

import { useState, useEffect, useCallback, useRef } from "react";
import { authFetch } from "@/lib/auth-fetch";
import type { DataUsedBlock } from "@/types/modem-status";

// =============================================================================
// useDataUsed — Persistent Data-Usage Counter Hook
// =============================================================================
// Polls /cgi-bin/quecmanager/network/data_used.sh at 2 s cadence to stay in
// sync with the poller's write rate. Provides a reset mutation that POSTs to
// data_used_reset.sh; the counter drops to ~0 within 4-5 s after a successful
// reset as the poller picks up the flag on its next tick.
//
// Usage:
//   const { data, isLoading, error, resetCounter, isResetting } = useDataUsed();
// =============================================================================

const FETCH_ENDPOINT = "/cgi-bin/quecmanager/network/data_used.sh";
const RESET_ENDPOINT = "/cgi-bin/quecmanager/network/data_used_reset.sh";
const DEFAULT_POLL_INTERVAL = 2000;

export interface UseDataUsedReturn {
  /** Latest data-usage block (null before first successful fetch) */
  data: DataUsedBlock | null;
  /** True during the very first fetch */
  isLoading: boolean;
  /** True while a reset POST is in-flight */
  isResetting: boolean;
  /** Error message if the last fetch failed */
  error: string | null;
  /** POST a reset request. Returns true on success. */
  resetCounter: () => Promise<boolean>;
  /** Manually trigger an immediate refresh */
  refresh: () => void;
}

export function useDataUsed(): UseDataUsedReturn {
  const [data, setData] = useState<DataUsedBlock | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [isResetting, setIsResetting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const mountedRef = useRef(true);
  const intervalRef = useRef<ReturnType<typeof setInterval> | null>(null);
  // Prevents request pile-up at 2s polling if the device is briefly slow.
  const inFlightRef = useRef(false);

  const fetchData = useCallback(async () => {
    if (inFlightRef.current) return; // a request is still pending — skip
    inFlightRef.current = true;
    try {
      const response = await authFetch(FETCH_ENDPOINT);
      if (!response.ok) {
        throw new Error(`HTTP ${response.status}: ${response.statusText}`);
      }
      const json: DataUsedBlock = await response.json();
      if (!mountedRef.current) return;

      setData(json);
      setError(null);
      setIsLoading(false);
    } catch (err) {
      if (!mountedRef.current) return;
      const message =
        err instanceof Error ? err.message : "Failed to fetch data usage";
      setError(message);
      setIsLoading(false);
    } finally {
      inFlightRef.current = false;
    }
  }, []);

  // ---------------------------------------------------------------------------
  // Reset mutation
  // ---------------------------------------------------------------------------
  const resetCounter = useCallback(async (): Promise<boolean> => {
    setIsResetting(true);
    try {
      const response = await authFetch(RESET_ENDPOINT, { method: "POST" });
      if (!response.ok) {
        throw new Error(`HTTP ${response.status}: ${response.statusText}`);
      }
      // Fire an immediate refresh so the UI doesn't wait a full 2 s interval
      await fetchData();
      return true;
    } catch (err) {
      return false;
    } finally {
      if (mountedRef.current) {
        setIsResetting(false);
      }
    }
  }, [fetchData]);

  // ---------------------------------------------------------------------------
  // Polling lifecycle
  // ---------------------------------------------------------------------------
  useEffect(() => {
    mountedRef.current = true;

    const startInterval = () => {
      if (intervalRef.current) return;
      intervalRef.current = setInterval(fetchData, DEFAULT_POLL_INTERVAL);
    };
    const stopInterval = () => {
      if (intervalRef.current) {
        clearInterval(intervalRef.current);
        intervalRef.current = null;
      }
    };
    // Pause polling while the tab is hidden so a backgrounded/locked device
    // stops forking CGI processes; catch up immediately on return.
    const onVisibility = () => {
      if (document.hidden) {
        stopInterval();
      } else {
        fetchData();
        startInterval();
      }
    };

    fetchData();
    startInterval();
    document.addEventListener("visibilitychange", onVisibility);

    return () => {
      mountedRef.current = false;
      stopInterval();
      document.removeEventListener("visibilitychange", onVisibility);
    };
  }, [fetchData]);

  return {
    data,
    isLoading,
    isResetting,
    error,
    resetCounter,
    refresh: fetchData,
  };
}
