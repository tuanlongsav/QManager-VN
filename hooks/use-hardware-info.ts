"use client";

import { useState, useEffect, useCallback, useRef } from "react";
import { authFetch } from "@/lib/auth-fetch";
import type { HardwareInfo } from "@/types/hardware-info";

// =============================================================================
// useHardwareInfo — Fetch modem hardware snapshot
// =============================================================================
// Hardware info is effectively immutable for a given physical modem (model,
// firmware, IMEI don't change at runtime), so this hook caches aggressively:
// - In-memory cache shared across hook instances (module-level)
// - Single in-flight request guard (multiple components mounting in parallel
//   don't all fire requests)
// - 5-minute server re-fetch (covers the unlikely case where the user flashes
//   new firmware without a page reload)
//
// Backend: GET /cgi-bin/quecmanager/system/hardware-info.sh
// =============================================================================

const CGI_ENDPOINT = "/cgi-bin/quecmanager/system/hardware-info.sh";
const CACHE_TTL_MS = 5 * 60 * 1000;

let cachedInfo: HardwareInfo | null = null;
let cachedAt = 0;
let inFlight: Promise<HardwareInfo | null> | null = null;

async function fetchHardwareInfo(): Promise<HardwareInfo | null> {
  if (inFlight) return inFlight;

  inFlight = (async () => {
    try {
      const res = await authFetch(CGI_ENDPOINT);
      if (!res.ok) return null;
      const data = (await res.json()) as HardwareInfo;
      cachedInfo = data;
      cachedAt = Date.now();
      return data;
    } catch {
      return null;
    } finally {
      inFlight = null;
    }
  })();

  return inFlight;
}

export interface UseHardwareInfoReturn {
  hardware: HardwareInfo | null;
  isLoading: boolean;
  error: string | null;
  refresh: () => void;
}

export function useHardwareInfo(): UseHardwareInfoReturn {
  const [hardware, setHardware] = useState<HardwareInfo | null>(cachedInfo);
  const [isLoading, setIsLoading] = useState<boolean>(cachedInfo === null);
  const [error, setError] = useState<string | null>(null);
  const isMountedRef = useRef(true);

  const load = useCallback(async () => {
    // Serve fresh from cache if within TTL
    if (cachedInfo && Date.now() - cachedAt < CACHE_TTL_MS) {
      setHardware(cachedInfo);
      setIsLoading(false);
      return;
    }

    setIsLoading(true);
    const data = await fetchHardwareInfo();
    if (!isMountedRef.current) return;

    if (data) {
      setHardware(data);
      setError(null);
    } else {
      setError("Failed to load hardware info");
    }
    setIsLoading(false);
  }, []);

  useEffect(() => {
    isMountedRef.current = true;
    load();
    return () => {
      isMountedRef.current = false;
    };
  }, [load]);

  const refresh = useCallback(() => {
    cachedInfo = null;
    cachedAt = 0;
    load();
  }, [load]);

  return { hardware, isLoading, error, refresh };
}
