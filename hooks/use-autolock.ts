"use client";

import { useState, useEffect, useCallback, useRef } from "react";
import { authFetch } from "@/lib/auth-fetch";
import type {
  AutolockResponse,
  AutolockConfig,
  AutolockStatus,
} from "@/types/autolock";

// =============================================================================
// useAutolock — Fetch + save auto cell-lock config & live status
// =============================================================================
// Polls every 3s while mounted so the state machine indicator updates in
// near-real-time. Polling stops on unmount.
//
// Backend: GET/POST /cgi-bin/quecmanager/cellular/autolock.sh
// =============================================================================

const CGI_ENDPOINT = "/cgi-bin/quecmanager/cellular/autolock.sh";
const POLL_INTERVAL_MS = 3000;

export interface SavePayload {
  enabled?: boolean;
  rsrp_stable?: number;
  sinr_stable?: number;
  rsrp_lost?: number;
  samples?: number;
}

export interface UseAutolockReturn {
  config: AutolockConfig | null;
  status: AutolockStatus | null;
  serviceActive: boolean;
  isLoading: boolean;
  isSaving: boolean;
  error: string | null;
  save: (payload: SavePayload) => Promise<boolean>;
  refresh: () => void;
}

export function useAutolock(): UseAutolockReturn {
  const [config, setConfig] = useState<AutolockConfig | null>(null);
  const [status, setStatus] = useState<AutolockStatus | null>(null);
  const [serviceActive, setServiceActive] = useState(false);
  const [isLoading, setIsLoading] = useState(true);
  const [isSaving, setIsSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const isMountedRef = useRef(true);

  const load = useCallback(async () => {
    try {
      const res = await authFetch(CGI_ENDPOINT);
      if (!res.ok) {
        if (isMountedRef.current) setError("Failed to load auto-lock config");
        return;
      }
      const data = (await res.json()) as AutolockResponse;
      if (!isMountedRef.current) return;
      setConfig(data.config);
      setStatus(data.status);
      setServiceActive(data.service_active);
      setError(null);
    } catch {
      if (isMountedRef.current) setError("Network error loading auto-lock");
    } finally {
      if (isMountedRef.current) setIsLoading(false);
    }
  }, []);

  useEffect(() => {
    isMountedRef.current = true;
    load();
    const id = setInterval(load, POLL_INTERVAL_MS);
    return () => {
      isMountedRef.current = false;
      clearInterval(id);
    };
  }, [load]);

  const save = useCallback(
    async (payload: SavePayload): Promise<boolean> => {
      setIsSaving(true);
      try {
        const res = await authFetch(CGI_ENDPOINT, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ action: "save", ...payload }),
        });
        if (!res.ok) {
          if (isMountedRef.current) setError("Failed to save auto-lock config");
          return false;
        }
        // Refresh after save so UI reflects new state
        await load();
        return true;
      } catch {
        if (isMountedRef.current) setError("Network error saving auto-lock");
        return false;
      } finally {
        if (isMountedRef.current) setIsSaving(false);
      }
    },
    [load],
  );

  return {
    config,
    status,
    serviceActive,
    isLoading,
    isSaving,
    error,
    save,
    refresh: load,
  };
}
