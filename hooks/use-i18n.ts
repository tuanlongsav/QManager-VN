"use client";

import { useState, useEffect, useCallback } from "react";
import en from "@/lib/i18n/en.json";
import vi from "@/lib/i18n/vi.json";

// =============================================================================
// useT — Lightweight i18n hook for QManager-VN
// =============================================================================
// Two languages: English (en) and Tiếng Việt (vi). No external dep — pure
// JSON lookup + localStorage preference + module-level event bus so all hook
// instances in the same tab update synchronously when the user toggles.
//
// Design notes:
//   - Default = "vi" since the fork's primary audience is Vietnamese.
//   - If the browser advertises `vi-*` we honor that on first paint.
//   - Translations are eagerly bundled (the JSON files are tiny — <10 KB total
//     gzipped). No code-splitting overhead.
//   - Missing keys fall back to the raw key string (visible to maintainers
//     during development so they notice gaps), or an explicit fallback arg.
//   - {{var}} placeholders interpolate from a values map.
// =============================================================================

type TranslationMap = typeof en;
const translations: Record<string, TranslationMap> = { en, vi };
export type Lang = "en" | "vi";

const STORAGE_KEY = "qmanager_vn_lang";
const DEFAULT_LANG: Lang = "vi";

// Module-level subscribers so a setLang() call in one component re-renders
// every other component using the hook within the same tab. Cross-tab sync
// works automatically via the native `storage` event.
type Listener = (lang: Lang) => void;
const listeners = new Set<Listener>();

function detectBrowserLang(): Lang {
  if (typeof navigator === "undefined") return DEFAULT_LANG;
  return navigator.language.toLowerCase().startsWith("vi") ? "vi" : "en";
}

function readStored(): Lang {
  if (typeof window === "undefined") return DEFAULT_LANG;
  const stored = window.localStorage.getItem(STORAGE_KEY);
  if (stored === "en" || stored === "vi") return stored;
  return detectBrowserLang();
}

function interpolate(template: string, values?: Record<string, string | number>): string {
  if (!values) return template;
  return template.replace(/\{\{(\w+)\}\}/g, (_, key) =>
    key in values ? String(values[key]) : `{{${key}}}`,
  );
}

function lookupKey(map: unknown, key: string): string | undefined {
  const parts = key.split(".");
  let cur: unknown = map;
  for (const p of parts) {
    if (cur && typeof cur === "object" && p in (cur as Record<string, unknown>)) {
      cur = (cur as Record<string, unknown>)[p];
    } else {
      return undefined;
    }
  }
  return typeof cur === "string" ? cur : undefined;
}

export interface UseTReturn {
  lang: Lang;
  setLang: (next: Lang) => void;
  /**
   * Translate a dotted key (e.g. "dashboard.temperature"). Optional `values`
   * map fills `{{var}}` placeholders. Optional `fallback` overrides the
   * "show the raw key" default behavior.
   */
  t: (key: string, valuesOrFallback?: Record<string, string | number> | string, fallback?: string) => string;
}

export function useT(): UseTReturn {
  const [lang, setLangState] = useState<Lang>(DEFAULT_LANG);

  useEffect(() => {
    setLangState(readStored());

    const onStorage = (e: StorageEvent) => {
      if (e.key === STORAGE_KEY) setLangState(readStored());
    };
    window.addEventListener("storage", onStorage);

    const onInternal: Listener = (l) => setLangState(l);
    listeners.add(onInternal);

    return () => {
      window.removeEventListener("storage", onStorage);
      listeners.delete(onInternal);
    };
  }, []);

  const setLang = useCallback((next: Lang) => {
    if (typeof window !== "undefined") {
      window.localStorage.setItem(STORAGE_KEY, next);
    }
    setLangState(next);
    listeners.forEach((cb) => cb(next));
  }, []);

  const t = useCallback(
    (
      key: string,
      valuesOrFallback?: Record<string, string | number> | string,
      fallback?: string,
    ): string => {
      // Allow both `t("key", "fallback")` and `t("key", { val: 5 }, "fallback")`
      let values: Record<string, string | number> | undefined;
      let fb: string | undefined;
      if (typeof valuesOrFallback === "string") {
        fb = valuesOrFallback;
      } else {
        values = valuesOrFallback;
        fb = fallback;
      }

      const primary = lookupKey(translations[lang], key);
      if (primary !== undefined) return interpolate(primary, values);

      // Fall back to English so a missing VN key still renders a real word.
      const enFallback = lookupKey(translations.en, key);
      if (enFallback !== undefined) return interpolate(enFallback, values);

      return fb ?? key;
    },
    [lang],
  );

  return { lang, setLang, t };
}
