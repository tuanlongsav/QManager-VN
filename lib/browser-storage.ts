/**
 * The one way this app touches localStorage and sessionStorage.
 *
 * WHY A SHARED MODULE, when the body of each helper is three lines. The bug
 * this file exists to end was never "somebody forgot a try/catch" — it was five
 * hand-rolled guards, no two alike, each protecting the call sites its author
 * happened to know about. A guard that covers three of four accesses is worth
 * exactly as much as no guard at all, because the one it misses is the one that
 * throws. So: no local re-implementations. Import from here.
 *
 * WHY IT CAN THROW AT ALL, when `localStorage.getItem` looks so harmless: it is
 * not the method that fails, it is the *property lookup*. Merely evaluating
 * `localStorage` throws a SecurityError in any document the browser has denied
 * storage to —
 *
 *   - a cross-origin iframe without `allow-same-origin` (a QManager tab embedded
 *     in a router-management dashboard is exactly this),
 *   - Safari with "block all cookies" set,
 *   - several embedded WebViews, including the one in some Android carrier apps,
 *
 * and `setItem` additionally throws QuotaExceededError once the origin's quota
 * is full — Safari's old private mode reported a quota of zero bytes, so *every*
 * write threw there. Finally, during the static-export prerender there is no
 * such global at all, which is a ReferenceError, not a SecurityError.
 *
 * `try` catches all four. A `typeof window !== "undefined"` check catches only
 * the last one, and that is precisely the check this codebase kept reaching for.
 *
 * WHY IT MATTERS SO MUCH HERE. QManager is a static export: every page load is a
 * hydration, and a throw inside a `useState` initializer or anywhere on a render
 * path takes down the whole React tree. On a headless modem whose only UI is
 * this page, a blank screen means the box needs SSH to be usable again. A
 * language preference that cannot be read is a triviality; the crash it causes
 * is not.
 *
 * FAILURE SEMANTICS, uniform across every helper: reads report unreachability,
 * writes report whether they happened, removals are best-effort. Nothing in this
 * file throws, ever. Callers decide what to do with a degraded store — and the
 * right answer is almost always "carry on with a default", never "show an error".
 */

/** Which of the two Web Storage areas a call refers to. */
export type StorageArea = "local" | "session";

/**
 * Returned by readStorageValue when the storage area could not be reached.
 *
 * KEEP THIS DISTINCT FROM `null`. "The key is not set" and "there is no storage"
 * are different answers, and lib/session.ts learned the difference the hard way:
 * its redirect budget counts auth bounces in sessionStorage, an absent key means
 * "this tab has not bounced yet, count from zero", and an unreachable store means
 * "the loop breaker is blind, fail open". Collapsing both to `null` made the
 * count unreadable *and* unwritable, which silently disabled the loop breaker in
 * exactly the browsers most likely to need it.
 *
 * A caller that genuinely does not care can say so out loud with
 * readStorageValueOrNull() below — the collapse is then visible in the code.
 */
export const STORAGE_UNREACHABLE = Symbol("browser-storage-unreachable");

/** `string` = the stored value, `null` = key absent, symbol = no storage. */
export type StorageReadResult = string | null | typeof STORAGE_UNREACHABLE;

/**
 * Resolve a storage area, or `null` if it cannot be touched at all.
 *
 * The property access lives here, alone, inside the try — everything else in the
 * file goes through it, so there is a single place where the SecurityError can
 * originate.
 */
function getArea(area: StorageArea): Storage | null {
  try {
    return area === "local" ? window.localStorage : window.sessionStorage;
  } catch {
    return null;
  }
}

/**
 * Read a key. Never throws.
 *
 * @returns the stored string, `null` when the key is absent, or
 *   STORAGE_UNREACHABLE when this document has no usable storage.
 */
export function readStorageValue(
  area: StorageArea,
  key: string
): StorageReadResult {
  const store = getArea(area);
  if (store === null) return STORAGE_UNREACHABLE;
  try {
    return store.getItem(key);
  } catch {
    // Firefox has been seen throwing from getItem itself (dom.storage.enabled
    // flipped mid-session) even though the property read succeeded, so the
    // method call gets its own guard rather than trusting getArea's verdict.
    return STORAGE_UNREACHABLE;
  }
}

/**
 * Read a key, treating "no storage" the same as "not set".
 *
 * For the many callers whose answer to both is identical — a remembered UI
 * preference, a cached avatar, a draft — and who would otherwise write the same
 * `=== STORAGE_UNREACHABLE ? null : v` line each. Use readStorageValue instead
 * whenever the two cases lead to different behaviour; see the note on
 * STORAGE_UNREACHABLE for what happens when that distinction is dropped by
 * accident rather than on purpose.
 */
export function readStorageValueOrNull(
  area: StorageArea,
  key: string
): string | null {
  const value = readStorageValue(area, key);
  return value === STORAGE_UNREACHABLE ? null : value;
}

/**
 * Write a key. Never throws.
 *
 * @returns whether the value will actually be readable back later. Callers that
 *   only cache a convenience can ignore it; callers whose *correctness* depends
 *   on the value surviving (a marker another page reads, a counter that limits
 *   something) must not — see prepareForReboot in lib/session.ts for what a
 *   silently dropped write costs.
 */
export function writeStorageValue(
  area: StorageArea,
  key: string,
  value: string
): boolean {
  const store = getArea(area);
  if (store === null) return false;
  try {
    store.setItem(key, value);
    return true;
  } catch {
    // QuotaExceededError, or a store that turned read-only under us.
    return false;
  }
}

/** Remove a key. Best effort: nothing to remove if there is no storage. */
export function removeStorageValue(area: StorageArea, key: string): void {
  const store = getArea(area);
  if (store === null) return;
  try {
    store.removeItem(key);
  } catch {
    // Nothing sensible to do, and nothing that depends on the removal having
    // happened: a store we cannot write is a store nobody can read our value
    // back out of either.
  }
}

/**
 * Is this area usable at all?
 *
 * Only for UI that must *decide what to render* — hiding a "remember this
 * device" switch that could not remember anything, for example. Do not use it to
 * pre-check before a read or a write: the helpers above already handle failure,
 * and a check followed by an unguarded access is the pattern that produced this
 * module's whole reason for existing.
 */
export function isStorageAvailable(area: StorageArea): boolean {
  return getArea(area) !== null;
}
