"use client";

import { useState, useEffect, useCallback, useRef } from "react";
import { toast } from "sonner";
import { authFetch } from "@/lib/auth-fetch";
import {
  readStorageValueOrNull,
  removeStorageValue,
  writeStorageValue,
} from "@/lib/browser-storage";
import type { CellScanResult } from "@/components/cellular/cell-scanner/scan-result";

// Poll interval while a scan is running (ms)
const SCAN_POLL_INTERVAL = 2000;
// sessionStorage key for persisting scan start time across navigations
const SCAN_START_KEY = "qm_cell_scan_start";

type ScanStatus = "idle" | "running" | "complete" | "error";

interface CellScanStatusResponse {
  status: ScanStatus;
  results?: CellScanResult[];
  message?: string;
}

interface UseCellScannerReturn {
  status: ScanStatus;
  results: CellScanResult[];
  error: string | null;
  elapsedSeconds: number;
  startScan: () => Promise<void>;
}

export function useCellScanner(): UseCellScannerReturn {
  const [status, setStatus] = useState<ScanStatus>("idle");
  const [results, setResults] = useState<CellScanResult[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [elapsedSeconds, setElapsedSeconds] = useState(0);
  const pollRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const timerRef = useRef<ReturnType<typeof setInterval> | null>(null);
  // Ref to always hold the latest pollStatus for use in setInterval callbacks,
  // avoiding stale closures when pollStatus is recreated by useCallback.
  const pollStatusRef = useRef<() => Promise<void>>(null!);

  // --- Helpers: interval management ------------------------------------------
  const stopPolling = useCallback(() => {
    if (pollRef.current) {
      clearInterval(pollRef.current);
      pollRef.current = null;
    }
  }, []);

  const stopTimer = useCallback(() => {
    if (timerRef.current) {
      clearInterval(timerRef.current);
      timerRef.current = null;
    }
  }, []);

  const startTimer = useCallback(
    (startTime: number) => {
      stopTimer();
      setElapsedSeconds(Math.floor((Date.now() - startTime) / 1000));
      timerRef.current = setInterval(() => {
        setElapsedSeconds(Math.floor((Date.now() - startTime) / 1000));
      }, 1000);
    },
    [stopTimer],
  );

  const finishScan = useCallback(() => {
    stopPolling();
    stopTimer();
    removeStorageValue("session", SCAN_START_KEY);
  }, [stopPolling, stopTimer]);

  /**
   * Resume (or begin) the elapsed-time display for a scan that is running.
   *
   * Both callers below needed the same four lines — read the remembered start,
   * invent one if there isn't a usable one, persist it, start ticking — and both
   * reached into sessionStorage bare. Sharing the routine is what keeps the
   * guard from being applied to one of them and forgotten on the other, which is
   * the failure mode this whole sweep exists to end.
   *
   * `readStorageValueOrNull` collapses "no such key" and "no storage at all"
   * deliberately: this timer wants a number or a fresh start, and both cases
   * mean the same thing to it. The consequence in a storage-blocked browser is
   * that the elapsed counter restarts from zero if the user navigates away and
   * back mid-scan. The scan itself is server-side and unaffected.
   *
   * The plausibility check on the parsed value is about the key's CONTENTS, not
   * about the storage layer. Two spellings of "unusable" reach here and neither
   * is caught by a truthiness test: a stale or hand-edited key parses to NaN, and
   * `Date.now() - NaN` propagates to a visible "NaN" in the elapsed counter,
   * while an empty string parses to 0 — a perfectly finite epoch of 1970, which
   * would report the scan as having run for fifty-odd years. Demanding a positive
   * finite number rejects both and falls back to "started just now".
   */
  const resumeElapsedTimer = useCallback(() => {
    const stored = readStorageValueOrNull("session", SCAN_START_KEY);
    const remembered = stored === null ? NaN : Number(stored);

    if (Number.isFinite(remembered) && remembered > 0) {
      startTimer(remembered);
      return;
    }

    const startTime = Date.now();
    writeStorageValue("session", SCAN_START_KEY, String(startTime));
    startTimer(startTime);
  }, [startTimer]);

  /** Start polling using the ref-based callback to avoid stale closures. */
  const ensurePolling = useCallback(() => {
    if (pollRef.current) return; // already polling
    pollRef.current = setInterval(
      () => pollStatusRef.current(),
      SCAN_POLL_INTERVAL,
    );
  }, []);

  // --- Poll for scan status --------------------------------------------------
  const pollStatus = useCallback(async () => {
    try {
      const res = await authFetch(
        `/cgi-bin/quecmanager/at_cmd/cell_scan_status.sh?_t=${Date.now()}`,
      );
      if (!res.ok) throw new Error(`HTTP ${res.status}`);

      const data: CellScanStatusResponse = await res.json();

      switch (data.status) {
        case "running":
          setStatus("running");
          // Fix: if we detect a running scan but have no polling interval
          // (mount-time detection), start one via the ref-based callback.
          ensurePolling();
          // If we detect a running scan but have no timer, restore it
          if (!timerRef.current) {
            resumeElapsedTimer();
          }
          break;

        case "complete": {
          const cells = data.results ?? [];
          setStatus("complete");
          setResults(cells);
          setError(null);
          finishScan();
          if (cells.length > 0) {
            toast.success("Scan complete", {
              description: `${cells.length} ${cells.length === 1 ? "cell" : "cells"} found`,
            });
          }
          break;
        }

        case "error":
          setStatus("error");
          setError(data.message ?? "Scan failed");
          finishScan();
          break;

        default:
          // "idle" — no scan running, no results
          // If we had a polling interval, the scan process died silently
          if (pollRef.current) {
            setStatus("idle");
            finishScan();
          }
          break;
      }
    } catch {
      // Network error during poll — keep retrying
    }
  }, [ensurePolling, finishScan, resumeElapsedTimer]);

  // Keep the ref in sync so interval callbacks always use the latest pollStatus
  pollStatusRef.current = pollStatus;

  // --- Start a new scan ------------------------------------------------------
  const startScan = useCallback(async () => {
    setStatus("running");
    setError(null);

    try {
      const res = await authFetch(
        "/cgi-bin/quecmanager/at_cmd/cell_scan_start.sh",
        { method: "POST" },
      );
      if (!res.ok) throw new Error(`HTTP ${res.status}`);

      const data = await res.json();

      if (!data.success) {
        if (data.error === "already_running") {
          // Scan already in progress — restore timer from sessionStorage, start polling
          setStatus("running");
          resumeElapsedTimer();
          ensurePolling();
          return;
        } else {
          setStatus("error");
          setError(data.detail || data.error || "Failed to start scan");
          return;
        }
      }

      // Store scan start time for elapsed timer persistence.
      //
      // This used to be a bare `sessionStorage.setItem` sitting inside the same
      // try/catch as the fetch, which made a storage failure indistinguishable
      // from a network one: the scan had just started successfully on the
      // device, and the user was told "Failed to connect to scanner" while the
      // poller was never started, leaving a real scan running with no UI
      // watching it. writeStorageValue cannot throw, so that branch is now
      // reachable only by the fetch it was written for.
      const startTime = Date.now();
      writeStorageValue("session", SCAN_START_KEY, String(startTime));
      startTimer(startTime);

      // Begin polling for results via ref-based callback
      stopPolling();
      pollRef.current = setInterval(
        () => pollStatusRef.current(),
        SCAN_POLL_INTERVAL,
      );
    } catch {
      setStatus("error");
      setError("Failed to connect to scanner");
    }
  }, [ensurePolling, resumeElapsedTimer, startTimer, stopPolling]);

  // --- Check for existing results on mount -----------------------------------
  useEffect(() => {
    pollStatus();
    return () => {
      stopPolling();
      stopTimer();
    };
  }, [pollStatus, stopPolling, stopTimer]);

  // --- beforeunload guard while scanning -------------------------------------
  useEffect(() => {
    if (status !== "running") return;

    const handleBeforeUnload = (e: BeforeUnloadEvent) => {
      e.preventDefault();
    };

    window.addEventListener("beforeunload", handleBeforeUnload);
    return () => window.removeEventListener("beforeunload", handleBeforeUnload);
  }, [status]);

  return { status, results, error, elapsedSeconds, startScan };
}
