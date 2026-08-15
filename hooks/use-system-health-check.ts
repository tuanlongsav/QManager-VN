"use client";

import { useState, useCallback, useRef, useEffect } from "react";
import { authFetch } from "@/lib/auth-fetch";
import { isAuthNavigationInFlight } from "@/lib/session";
import type {
  HealthCheckJob,
  RunResponse,
  TestOutputResponse,
  TestStatus,
} from "@/types/system-health-check";

const CGI_BASE = "/cgi-bin/quecmanager/system/health-check";
const POLL_INTERVAL_MS = 500;

export interface UseSystemHealthCheckReturn {
  job: HealthCheckJob | null;
  isRunning: boolean;
  isStarting: boolean;
  isClearing: boolean;
  error: string | null;
  start: () => Promise<void>;
  clear: () => Promise<void>;
  refresh: () => Promise<void>;
  fetchTestOutput: (testId: string) => Promise<string>;
  downloadBundle: () => void;
}

export function useSystemHealthCheck(): UseSystemHealthCheckReturn {
  const [job, setJob] = useState<HealthCheckJob | null>(null);
  const [isStarting, setIsStarting] = useState(false);
  const [isClearing, setIsClearing] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const pollTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const aborted = useRef(false);

  const fetchStatus = useCallback(async (): Promise<HealthCheckJob | null> => {
    const res = await authFetch(`${CGI_BASE}/status.sh`);
    if (!res.ok) throw new Error(`status ${res.status}`);
    const data = await res.json();
    if (data?.status === "none") return null;
    return data as HealthCheckJob;
  }, []);

  const refresh = useCallback(async () => {
    try {
      const next = await fetchStatus();
      if (aborted.current) return;
      setJob(next);
      setError(null);
    } catch (e) {
      if (aborted.current) return;
      setError(e instanceof Error ? e.message : String(e));
    }
  }, [fetchStatus]);

  // Initial fetch on mount.
  useEffect(() => {
    aborted.current = false;
    void refresh();
    return () => {
      aborted.current = true;
      if (pollTimer.current) clearTimeout(pollTimer.current);
    };
  }, [refresh]);

  // Polling loop while job is running.
  useEffect(() => {
    if (pollTimer.current) {
      clearTimeout(pollTimer.current);
      pollTimer.current = null;
    }
    if (!job || job.status !== "running") return;
    pollTimer.current = setTimeout(async () => {
      if (aborted.current) return;
      await refresh();
    }, POLL_INTERVAL_MS);
    return () => {
      if (pollTimer.current) clearTimeout(pollTimer.current);
    };
  }, [job, refresh]);

  const start = useCallback(async () => {
    setIsStarting(true);
    setError(null);
    try {
      const res = await authFetch(`${CGI_BASE}/run.sh`, { method: "POST" });
      const data = (await res.json()) as RunResponse;
      if (aborted.current) return;
      if (!data.success || !data.job_id) {
        throw new Error(data.detail || data.error || "run failed");
      }
      // Seed a synthetic "running" job so UI flips immediately and the
      // polling effect starts. The backend's real status overwrites this
      // on the next 500ms tick — no race with status.sh writing late.
      setJob({
        job_id: data.job_id,
        status: "running",
        started_at: data.started_at ?? Math.floor(Date.now() / 1000),
        finished_at: null,
        pid: 0,
        summary: { pass: 0, fail: 0, warn: 0, skip: 0, total: 0 },
        tests: [],
        tarball_path: null,
        tarball_size: null,
        error: null,
      });
    } catch (e) {
      if (aborted.current) return;
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      if (!aborted.current) setIsStarting(false);
    }
  }, []);

  const clear = useCallback(async () => {
    setIsClearing(true);
    setError(null);
    try {
      const res = await authFetch(`${CGI_BASE}/clear.sh`, { method: "POST" });
      const data = await res.json();
      if (aborted.current) return;
      if (!data?.success) {
        throw new Error(data?.detail || data?.error || "clear failed");
      }
      setJob(null);
    } catch (e) {
      if (aborted.current) return;
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      if (!aborted.current) setIsClearing(false);
    }
  }, []);

  const fetchTestOutput = useCallback(async (testId: string): Promise<string> => {
    const res = await authFetch(
      `${CGI_BASE}/status.sh?test_id=${encodeURIComponent(testId)}`,
    );
    if (!res.ok) throw new Error(`status ${res.status}`);
    const data = (await res.json()) as TestOutputResponse;
    if (!data.success) throw new Error(data.error || "fetch failed");
    return data.output ?? "";
  }, []);

  const downloadBundle = useCallback(() => {
    if (!job?.job_id || !job.tarball_path) return;

    // This document is on its way out for an auth reason, so there is nothing
    // left to download it into. Checking is cheap and spends nothing.
    if (isAuthNavigationInFlight()) return;

    const url = `${CGI_BASE}/download.sh?job_id=${encodeURIComponent(job.job_id)}`;

    // NOT a navigation, and deliberately NOT routed through navigateForAuth().
    //
    // download.sh answers with `Content-Disposition: attachment` (see
    // scripts/www/cgi-bin/quecmanager/system/health-check/download.sh), which
    // tells the browser to save the body as a file rather than render it. The
    // current document is never replaced: assigning `location.href` here starts
    // a download and this page carries on running, so none of the reasons the
    // auth guard exists — an in-flight document load being aborted and
    // restarted — apply.
    //
    // Sending it through the guard anyway would actively break things. The guard
    // latches "this document is leaving" *before* handing the URL to the
    // browser, and that latch is one-way by design because a real navigation
    // never comes back. A download does come back, so the latch would be stuck
    // on for the rest of the page's life: the auto-logout poller would stand
    // down, authFetch's 401 handler would go quiet, and a session that expired
    // after the user saved a diagnostics bundle could never hand them over to
    // /login/ again. It would also spend a redirect-budget hop on an action that
    // is not a redirect.
    //
    // The auth cookie rides along automatically, so an expired session gets
    // download.sh's JSON 401 instead of a file. That is a cosmetic wart (the
    // browser renders the JSON) and not worth pre-flighting with an extra
    // request: reaching this button means the status poller was answering 200
    // moments ago, and any real 401 on it has already started the hand-off that
    // the check above returns on.
    window.location.href = url;
  }, [job]);

  const isRunning = job?.status === "running";

  return {
    job,
    isRunning: !!isRunning,
    isStarting,
    isClearing,
    error,
    start,
    clear,
    refresh,
    fetchTestOutput,
    downloadBundle,
  };
}

// Helper for components: status → display label
export function testStatusLabel(s: TestStatus): string {
  switch (s) {
    case "pass": return "Pass";
    case "fail": return "Fail";
    case "warn": return "Warning";
    case "skip": return "Skipped";
    case "running": return "Running";
    case "pending": return "Pending";
  }
}
