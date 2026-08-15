"use client";

import { useCallback, useSyncExternalStore } from "react";
import { readStorageValue, writeStorageValue } from "@/lib/browser-storage";
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
type Listener = () => void;
const listeners = new Set<Listener>();

function subscribe(onStoreChange: Listener): () => void {
  // Same tab: setLang() notifies every listener directly.
  listeners.add(onStoreChange);
  // Other tabs: the browser fires `storage` on this one.
  const onStorage = (e: StorageEvent) => {
    if (e.key === STORAGE_KEY) onStoreChange();
  };
  window.addEventListener("storage", onStorage);

  return () => {
    listeners.delete(onStoreChange);
    window.removeEventListener("storage", onStorage);
  };
}

// The static-export prerender has no localStorage, so it reports the default.
// That keeps the first client paint identical to the prerendered HTML; React
// swaps in the stored preference immediately after hydration.
function getServerSnapshot(): Lang {
  return DEFAULT_LANG;
}

function detectBrowserLang(): Lang {
  // `navigator.language` is missing in a few embedded WebViews, so read it
  // defensively rather than calling .toLowerCase() on undefined. This function
  // is on the render path of nearly every component in the app; a throw here is
  // a blank screen on a device whose only UI is this page.
  const advertised =
    typeof navigator === "undefined" ? undefined : navigator.language;
  return advertised?.toLowerCase().startsWith("vi") ? "vi" : "en";
}

/**
 * The chosen language when localStorage refused the write, and only then.
 *
 * WHY it exists: a document with storage blocked (cross-origin iframe, Safari
 * with cookies off, some WebViews — see lib/browser-storage.ts) cannot persist
 * the preference, and without this the toggle would appear to do nothing at all:
 * setLang would notify every subscriber, each would re-read storage, get the old
 * answer back, and re-render identically. Holding the choice in module scope
 * makes the toggle work for the life of the document, which is the most the
 * browser will allow.
 *
 * WHY it is cleared on a successful write, rather than always set: while storage
 * *is* usable it must stay the single source of truth, or the `storage` event
 * from another tab would be read and then immediately overruled by this
 * variable, and the two tabs would disagree forever.
 */
let unpersistedLang: Lang | null = null;

/**
 * getSnapshot for useSyncExternalStore.
 *
 * Two properties this function must keep, both easy to break:
 *
 * 1. **It must never throw.** It runs during render, on every component that
 *    calls useT — which is nearly all of them. Reading the `localStorage`
 *    property itself throws SecurityError in a storage-blocked document, so the
 *    access goes through lib/browser-storage, which cannot throw. An unreadable
 *    preference then degrades to the browser's advertised language, exactly as
 *    an unset one does: for this hook the two really are the same answer, and
 *    nothing downstream needs to tell them apart.
 * 2. **It must be referentially stable.** React compares consecutive snapshots
 *    with Object.is; hand back a fresh object and it re-renders forever. Every
 *    return path here yields one of the two string literals "en" / "vi", which
 *    compare equal by value — never widen this to an object.
 */
function readStored(): Lang {
  if (unpersistedLang !== null) return unpersistedLang;
  const stored = readStorageValue("local", STORAGE_KEY);
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
  // The language preference lives in localStorage, not in React — so read it as
  // an external store rather than mirroring it into state. `readStored` returns
  // a plain string, so repeat calls compare equal and never loop.
  const lang = useSyncExternalStore(subscribe, readStored, getServerSnapshot);

  const setLang = useCallback((next: Lang) => {
    // A blocked or full store makes setItem throw, and this runs from a click
    // handler inside the language toggle — an uncaught throw there would leave
    // the listeners un-notified and the UI stuck mid-toggle. writeStorageValue
    // reports the failure instead, and we keep the choice in memory so the user
    // still gets the language they asked for, just not across reloads.
    if (writeStorageValue("local", STORAGE_KEY, next)) {
      unpersistedLang = null;
    } else {
      unpersistedLang = next;
    }
    // Every subscriber re-reads through `readStored` once notified.
    listeners.forEach((cb) => cb());
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
