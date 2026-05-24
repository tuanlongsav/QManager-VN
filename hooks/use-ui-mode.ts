"use client";

import { useState, useEffect, useCallback } from "react";

// =============================================================================
// useUiMode — QManager-VN dashboard density toggle
// =============================================================================
// Two modes:
// - "simple": gọn — network status, device status, live latency. Cho user
//   phổ thông chỉ muốn biết "sóng có khoẻ, mạng có chạy".
// - "pro": full dashboard (LTE/NR/SCC detail, device metrics, recent activities,
//   signal history chart). Cho power user theo dõi chi tiết.
//
// Preference is per-browser (localStorage), no backend sync. The user toggles
// via a switch in the dashboard header or System Settings.
// =============================================================================

export type UiMode = "simple" | "pro";

const STORAGE_KEY = "qmanager_vn_ui_mode";
const DEFAULT_MODE: UiMode = "simple";

// Listeners so multiple components can react to mode changes within the same tab
// (different tabs sync via the native `storage` event already).
type Listener = (mode: UiMode) => void;
const listeners = new Set<Listener>();

function readStored(): UiMode {
  if (typeof window === "undefined") return DEFAULT_MODE;
  const v = window.localStorage.getItem(STORAGE_KEY);
  return v === "pro" ? "pro" : v === "simple" ? "simple" : DEFAULT_MODE;
}

export function useUiMode(): {
  mode: UiMode;
  setMode: (mode: UiMode) => void;
  toggleMode: () => void;
  isSimple: boolean;
  isPro: boolean;
} {
  const [mode, setModeState] = useState<UiMode>(DEFAULT_MODE);

  useEffect(() => {
    setModeState(readStored());

    const onStorage = (e: StorageEvent) => {
      if (e.key === STORAGE_KEY) setModeState(readStored());
    };
    window.addEventListener("storage", onStorage);

    const onInternal: Listener = (m) => setModeState(m);
    listeners.add(onInternal);

    return () => {
      window.removeEventListener("storage", onStorage);
      listeners.delete(onInternal);
    };
  }, []);

  const setMode = useCallback((next: UiMode) => {
    if (typeof window !== "undefined") {
      window.localStorage.setItem(STORAGE_KEY, next);
    }
    setModeState(next);
    listeners.forEach((cb) => cb(next));
  }, []);

  const toggleMode = useCallback(() => {
    setMode(mode === "simple" ? "pro" : "simple");
  }, [mode, setMode]);

  return {
    mode,
    setMode,
    toggleMode,
    isSimple: mode === "simple",
    isPro: mode === "pro",
  };
}
