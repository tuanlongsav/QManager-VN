import {
  STORAGE_UNREACHABLE,
  readStorageValue,
  removeStorageValue,
  writeStorageValue,
} from "@/lib/browser-storage";

/** JS-readable login indicator set by the backend alongside HttpOnly session cookie. */
const LOGIN_INDICATOR = "qm_logged_in";

/**
 * Marker written by prepareForReboot() and read by the /reboot/ countdown page
 * to tell "the user asked for a reboot and we sent them here" apart from "the
 * user typed /reboot/ into the address bar".
 *
 * Exported so components/reboot/reboot-countdown.tsx can share the literal
 * rather than re-type it: two copies of a storage key are one rename away from
 * a page that silently never sees its own marker.
 */
export const REBOOT_SESSION_KEY = "qm_rebooting";

const AUTH_BOUNCE_KEY = "qm_auth_bounces";

/**
 * How many consecutive auth redirects may fire in one tab before the gates stop
 * redirecting and render something the user can act on instead.
 *
 * Three is enough to clear any legitimate chain (a single hop is the normal
 * case; two covers a hop that lands on a page which immediately hops on), and
 * low enough that a genuine ping-pong is stopped before the user notices more
 * than a flicker.
 *
 * Every counted edge in the app shares this one budget, and growing the set did
 * NOT force the number up. The counted edges are:
 *
 *   - the three auth gates: /dashboard/ (components/app-layout.tsx), /login/
 *     (components/auth/login-component.tsx, hooks/use-auth.ts) and /setup/
 *     (app/setup/page.tsx);
 *   - authFetch's 401 handler (lib/auth-fetch.ts);
 *   - the auto-logout poller (hooks/use-auto-logout.ts), which reaches the same
 *     verdict the 401 handler does but from the other direction — check.sh
 *     answers 200 with `authenticated:false` rather than 401 — and so has to be
 *     counted for the same reason;
 *   - the hand-offs that land ON a gate: onboarding completion
 *     (components/onboarding/steps/step-done.tsx) and the reboot countdown once
 *     the device answers again (components/reboot/reboot-countdown.tsx). They
 *     are not gates themselves, but their destination is one, so a gate that
 *     misreads the session bounces them straight back.
 *
 * Deliberately UNCOUNTED, via `countsAsBounce: false`: everything heading for
 * /reboot/ (nav-user, the MBN and IP-passthrough cards, the OTA installer), the
 * post-login hops in hooks/use-auth.ts that follow a verdict the backend just
 * gave us, and the escape links a refused gate renders. None of them can be part
 * of an auth cycle — see navigateForAuth's `countsAsBounce` note.
 *
 * The number holds because every legitimate chain still ends at a page that
 * reaches a definite verdict and calls clearAuthRedirectBudget, and the longest
 * chain that accumulates without a clear is two hops: a 401 (or a dead session
 * seen by the poller) on /dashboard/ sends the user to /login/, which on a fresh
 * install hands them on to /setup/, which then clears. Three leaves exactly one
 * hop of headroom for a chain that hands on twice before reaching a verdict.
 * Raising the ceiling would only buy a real ping-pong more laps before it is
 * caught.
 */
const MAX_AUTH_BOUNCES = 3;

// ---------------------------------------------------------------------------
// Browser storage access
// ---------------------------------------------------------------------------

/**
 * Every sessionStorage access in this module goes through lib/browser-storage,
 * and so does every localStorage access everywhere else in the app. The
 * uniformity is the point: a guard that protects three of four call sites is
 * indistinguishable from no guard at all, because the unprotected one is the one
 * that throws. That module carries the full explanation of *why* a bare
 * `sessionStorage.getItem` can throw four different ways; the short version is
 * that it is the property lookup, not the method call, that fails.
 *
 * These three aliases exist only so the call sites below read as prose about
 * sessions rather than about storage areas. They add no behaviour — do not grow
 * any into this file, put it in lib/browser-storage.ts where every caller gets
 * it.
 *
 * Failure semantics, uniform: reads report unreachability (distinctly from "key
 * absent", which the redirect budget depends on telling apart — see
 * STORAGE_UNREACHABLE), writes report that they did not happen. Nothing throws.
 */
const readSessionValue = (key: string) => readStorageValue("session", key);
const writeSessionValue = (key: string, value: string) =>
  writeStorageValue("session", key, value);
const removeSessionValue = (key: string) => removeStorageValue("session", key);

/**
 * `document.cookie` is guarded for the same reason as sessionStorage above: the
 * accessor itself throws SecurityError in a document with an opaque origin. A
 * cookie we cannot read is one that is not there as far as this app can tell,
 * so both helpers degrade to "logged out" rather than to an exception.
 */
function getCookieValue(name: string): string | null {
  if (typeof document === "undefined") return null;
  let jar: string;
  try {
    jar = document.cookie;
  } catch {
    return null;
  }
  const prefix = `${name}=`;
  for (const part of jar.split(";")) {
    const trimmed = part.trim();
    if (trimmed.startsWith(prefix)) {
      return trimmed.slice(prefix.length);
    }
  }
  return null;
}

export function isLoggedIn(): boolean {
  return getCookieValue(LOGIN_INDICATOR) === "1";
}

export function clearIndicatorCookie(): void {
  try {
    document.cookie = `${LOGIN_INDICATOR}=; Path=/; Max-Age=0`;
  } catch {
    // A document that cannot write cookies cannot have set this one either, so
    // there is nothing to clear and isLoggedIn() already answers false.
  }
}

/**
 * Call before navigating to /reboot/ so the countdown page and OTA worker sync.
 *
 * Ordering is deliberate, and it only matters in the failure case. Clearing the
 * indicator cookie is the operation that must not be skipped: the reboot wipes
 * /tmp/qmanager_sessions, so the session is gone no matter what, and a stale
 * "logged in" cookie left behind means the dashboard gate waves the user
 * through to a page whose every request will 401. Writing the reboot marker only
 * decides which of two harmless pages they land on. So the cookie goes first,
 * where no storage failure can jump over it — this used to be the other way
 * round, and a throwing `setItem` took clearIndicatorCookie() with it.
 *
 * @returns whether the marker was persisted. It is not decoration: the countdown
 * page (components/reboot/reboot-countdown.tsx) treats a missing marker as
 * direct URL access and bounces to "/", so a `false` here means /reboot/ will
 * refuse the visit. A caller that cares should send the user to /login/ instead
 * and let them watch for the device coming back — the reboot itself has already
 * been requested by then, so there is nothing to undo, only somewhere better to
 * wait. Ignoring the result is safe but gives that user a bounce.
 */
export function prepareForReboot(): boolean {
  clearIndicatorCookie();
  return writeSessionValue(REBOOT_SESSION_KEY, "1");
}

// ---------------------------------------------------------------------------
// Session state as a React external store
// ---------------------------------------------------------------------------

/**
 * What a render pass is allowed to believe about the session.
 *
 * The third state is the whole point. A gate that only knows "in" and "out" has
 * to answer "out" before it has read anything, and "out" is an instruction to
 * redirect — so the gate ends up acting on the absence of information as if it
 * were information.
 */
export type SessionState = "unknown" | "authenticated" | "anonymous";

/** Client snapshot: the cookie is readable here, so the answer is definite. */
export function getSessionSnapshot(): SessionState {
  return isLoggedIn() ? "authenticated" : "anonymous";
}

/**
 * Server/hydration snapshot. It returns "unknown", and that is NOT an oversight
 * to be tidied away — do not "simplify" it back to "anonymous" or `false`.
 *
 * WHY: this app is a Next.js static export (`output: "export"`). There is no
 * Node server at runtime; every single page load is React hydrating prerendered
 * HTML, so getServerSnapshot runs on EVERY load, not just on a real SSR request.
 * A snapshot of `false` therefore means "logged out on every load, for the first
 * commit" — including for a user who is perfectly logged in. Any effect that
 * reacts to "logged out" then fires during that first commit and navigates away
 * before React can re-render with the client snapshot. That is exactly the
 * v1.0.4-vn bug: /dashboard/ -> /login/ -> /dashboard/ as full page loads,
 * forever, on a device with no other UI.
 *
 * "unknown" is the honest answer at hydration time: the prerendered HTML was
 * built on a machine that never saw this user's cookie. Callers must treat it as
 * "wait", never as "deny".
 *
 * Returns a string literal so the value is referentially stable across calls —
 * React compares consecutive snapshots with Object.is and warns (then loops) if
 * a fresh object is handed back each time.
 */
export function getSessionServerSnapshot(): SessionState {
  return "unknown";
}

const noopUnsubscribe = () => {};

/**
 * Deliberately a no-op subscription: the gate is a one-shot check.
 *
 * React still delivers the post-hydration correction without it — on mount it
 * schedules a passive effect that re-reads getSnapshot and forces a re-render
 * when it differs from the snapshot used during hydration. Subscribing only
 * matters for changes AFTER that.
 *
 * We do not want those. The one cookie mutation we control in-page is
 * clearIndicatorCookie(), and prepareForReboot() calls it *while the dashboard
 * is still mounted* on its way to /reboot/. A live subscription would wake the
 * gate at that moment and race a redirect to /login/ against the reboot
 * navigation. Session expiry is already covered elsewhere, and by better means:
 * authFetch redirects on a 401, and useAutoLogout polls auth/check.sh — both of
 * which ask the backend rather than trusting a client-side cookie.
 */
export function subscribeToSession(): () => void {
  return noopUnsubscribe;
}

// ---------------------------------------------------------------------------
// The auth navigation guard
// ---------------------------------------------------------------------------
//
// Read this before writing `window.location.href = ` anywhere in the app: there
// is exactly one way to navigate, navigateForAuth() below, and as of this sweep
// everything else goes through it. That is now literally true and worth keeping
// true — the only remaining assignments to `window.location.href` outside this
// file are (a) inside navigateForAuth itself and (b) the health-check bundle
// download in hooks/use-system-health-check.ts, which is not a navigation at all
// (the response carries `Content-Disposition: attachment`, so the browser saves
// a file and this document stays exactly where it is; see the comment there for
// why routing it through the guard would be actively harmful).
//
// WHY one way. Assigning `window.location.href` aborts whatever document load is
// in flight and starts a new one. Two call sites that each decide, correctly and
// independently, that the user belongs at /login/ therefore do not produce one
// redirect — they produce a load that gets cancelled and restarted, and on a
// modem where the new document can take tens of seconds to arrive (busy AT
// queue, lighttpd swapping /www during an OTA) a third and a fourth arrive
// before the first ever finished. The user sees a page that never settles. A
// full enumeration found eleven such sites in this app; the handful that had a
// guard at all had a different one each, and three of those were wrong in three
// different ways. Three rounds of fixes each patched only the sites their author
// knew about, which is the real reason this is centralised rather than reviewed.
//
// TWO CONCEPTS, ONE ENTRY POINT. The guard is built from two mechanisms that
// answer genuinely different questions, and merging them would break both:
//
//   * the IN-FLIGHT LATCH (`authNavigationInFlight`, module scope) answers
//     "has THIS document already committed to leaving?". Its lifetime is one
//     document, it is one-way, and it is never reset — a same-origin navigation
//     has no path back here, so a reset could only ever be wrong.
//   * the REDIRECT BUDGET (AUTH_BOUNCE_KEY, sessionStorage) answers "how many
//     auth redirects have fired in a row ACROSS documents?". It has to outlive
//     the document precisely because a ping-pong is invisible from inside any
//     single one of them, and it must be clearable, because a chain that ends
//     legitimately has to leave the next one a clean slate.
//
// Give the budget the latch's job and one 401 spends a hop that was meant to
// catch a loop; give the latch the budget's job and it dies with the document
// that set it, which is the same as not having it. So they stay separate — but
// callers get one function that consults both, because a caller that has to
// remember two mechanisms is a caller that will remember one.

/**
 * What happened to a requested navigation.
 *
 * - `started` — the browser is now leaving. Do nothing further; there is no
 *   "after" in this document worth writing code for.
 * - `suppressed` — nothing to do, and nothing wrong: this document is already
 *   on its way out, or it is already at the destination. Callers with ongoing
 *   work (pollers, retry clocks) should stand down permanently. Do NOT show the
 *   user an error; the hand-off is happening, just not because of this call.
 * - `refused` — the loop breaker vetoed it. The navigation will never happen,
 *   so a caller that renders a "handing you over" screen must instead render
 *   something the user can act on, typically a plain <a> to the destination.
 *   A user-initiated click is outside the budget and always works.
 */
export type AuthNavigationOutcome = "started" | "suppressed" | "refused";

/**
 * Set the instant this document commits to a full-page auth navigation.
 *
 * Module scope, not a ref or React state, because what is being remembered is a
 * fact about the *document* ("a navigation is already on its way"), and the
 * document outlives every component mounted in it. A ref is reset by a remount,
 * and a remount during the seconds a load is in flight is perfectly ordinary.
 */
let authNavigationInFlight = false;

/**
 * True once any part of the app has started a full-page navigation for an auth
 * reason — a 401 from authFetch, the auto-logout poller, or a gate hand-off.
 *
 * Two kinds of caller need this:
 *
 * - Anything that *reacts to failure* — offline detection, retry loops, error
 *   banners, toasts. Once this is true their "failure" is a session ending, not
 *   the condition they watch for, and every request they make from here is
 *   racing a document load that is already in progress.
 * - Anything with a repeating timer. Standing down means stopping, not skipping
 *   a tick: the next tick has exactly the same problem as this one.
 *
 * Callers that only read data can ignore it.
 */
export function isAuthNavigationInFlight(): boolean {
  return authNavigationInFlight;
}

/**
 * Former name of isAuthNavigationInFlight, kept because hooks/use-software-update.ts
 * and hooks/use-auto-logout.ts import it from "@/lib/auth-fetch" (which re-exports
 * this). Same latch, same answer — the flag simply moved out of auth-fetch when
 * it stopped being a 401-only concern.
 */
export function isSessionRedirectInFlight(): boolean {
  return authNavigationInFlight;
}

/** "/login/" and "/login" are the same page; compare them as such. */
function normalizePath(path: string): string {
  return path.length > 1 && path.endsWith("/") ? path.slice(0, -1) : path;
}

/**
 * Is `destination` the document we are already displaying?
 *
 * This is the ONLY question `window.location.pathname` can answer here, and
 * saying so precisely matters — see the note in navigateForAuth.
 */
function isCurrentDocument(destination: string): boolean {
  const [destPath] = destination.split(/[?#]/, 1);
  return normalizePath(destPath) === normalizePath(window.location.pathname);
}

/**
 * Navigate the browser for an auth reason. At most once per document, no matter
 * how many callers race.
 *
 * Safe to call from anywhere — a poller callback, a passive effect, a click
 * handler — and safe to call repeatedly: after the first `started` every later
 * call is `suppressed` without touching `window.location` and without spending
 * budget. That is what makes it usable from code that cannot know what the rest
 * of the page is doing, which on the dashboard is all of it: half a dozen
 * pollers run in parallel and one session expiry lands a 401 in every one of
 * them within the same second.
 *
 * @param destination Absolute path, query and hash allowed ("/login/?reason=offline").
 * @param options.countsAsBounce Whether this navigation spends the cross-document
 *   redirect budget. Default `true`, and the default is the safe direction: an
 *   uncounted edge is invisible to the loop breaker, which is exactly how the
 *   /setup/ route once let a /login/ ↔ /setup/ cycle run unbounded. Pass `false`
 *   only for a navigation that provably cannot be part of an auth cycle because
 *   it does not lead back to a gate — /reboot/ (the device is going down) and
 *   the escape links a refused gate renders (a human clicked, so a loop would
 *   need a human in it).
 */
export function navigateForAuth(
  destination: string,
  options?: { countsAsBounce?: boolean }
): AuthNavigationOutcome {
  // No browser during the static-export prerender. Nothing to navigate, and
  // nothing to report to a user who is not there yet.
  if (typeof window === "undefined") return "suppressed";

  if (authNavigationInFlight) {
    console.debug(
      `[auth] Already navigating; ignoring a second request for ${destination}.`
    );
    return "suppressed";
  }

  // Navigating to the page we are on is a document reload, and a reload that
  // re-runs the code path that asked for it is a loop with no exit. This is what
  // the pathname check in authFetch was really for — see the comment there for
  // what it is NOT for.
  if (isCurrentDocument(destination)) return "suppressed";

  if ((options?.countsAsBounce ?? true) && !claimAuthRedirect(destination)) {
    return "refused";
  }

  // Latch before the assignment, not after. The assignment does not stop this
  // function, this task, or anything else the page has queued — it only tells
  // the browser to start fetching. Everything that runs between now and the
  // document being torn down has to see the latch already set, or it will queue
  // a second fetch and cancel the first.
  authNavigationInFlight = true;
  window.location.href = destination;
  return "started";
}

// ---------------------------------------------------------------------------
// Redirect budget (loop breaker)
// ---------------------------------------------------------------------------

/**
 * Records an auth redirect and reports whether the caller may perform it.
 *
 * Prefer navigateForAuth() — it consults this *and* the in-flight latch, and a
 * caller that claims a redirect here without checking the latch has only solved
 * the across-documents half of the problem. This stays exported for the gates
 * that need to spend the budget at a moment other than the navigation itself.
 *
 * The auth gates point at each other by design — /dashboard/ sends a logged-out
 * user to /login/, /login/ sends a logged-in user to /dashboard/ (and a fresh
 * install on to /setup/), and /setup/ sends a logged-in user back to
 * /dashboard/ or a configured-but-logged-out one to /login/. Each is correct
 * alone, but if any one of them ever misreads the session the set becomes a
 * full-page-navigation loop that no amount of clicking can escape. On a
 * headless modem that is the difference between "one wrong page" and "the box
 * needs SSH to be usable again".
 *
 * This budget is a blast-radius limiter, not a cure: it does not make a wrong
 * answer right, it only stops the wrong answer from being repeated. It stays
 * loud on purpose — it logs, and the page the user lands on is visibly the
 * wrong one for their session, so the underlying bug still gets reported
 * instead of being smoothed over.
 *
 * Fails open: if sessionStorage is unavailable, redirects behave as before.
 */
export function claimAuthRedirect(destination: string): boolean {
  const stored = readSessionValue(AUTH_BOUNCE_KEY);
  // No readable storage means no budget to be out of: fail open, exactly as the
  // read-only companion below does. An absent key is a different thing entirely
  // — it is a tab that has not redirected yet, and it counts from zero.
  if (stored === STORAGE_UNREACHABLE) return true;

  const count = Number(stored) || 0;

  if (count >= MAX_AUTH_BOUNCES) {
    console.error(
      `[auth] Refusing to redirect to ${destination}: ${count} consecutive auth ` +
        `redirects from ${window.location.pathname}. The login gate and the ` +
        `dashboard gate disagree about the session — this is a bug, please report it.`
    );
    return false;
  }

  // A failed write leaves the count where it was, so the budget stops counting
  // rather than stopping the user. Same direction as every other fallback here.
  writeSessionValue(AUTH_BOUNCE_KEY, String(count + 1));
  return true;
}

/**
 * Read-only companion to claimAuthRedirect: would the next claim be refused?
 *
 * A gate's render pass runs *before* its effect, so at the moment it has to
 * decide what to put on screen it does not yet know whether the redirect it is
 * about to attempt will be allowed. This answers that question without spending
 * anything, letting a gate render "handing you over" versus "the hand-off is
 * never coming" correctly on the first commit instead of accusing every
 * logged-out visitor of a broken session.
 *
 * It tests the same count against the same limit as claimAuthRedirect, so the
 * two cannot disagree — keep them that way if either ever grows a condition.
 *
 * Fails open in the same direction: no storage means no budget to be out of.
 */
export function isAuthRedirectBudgetExhausted(): boolean {
  const stored = readSessionValue(AUTH_BOUNCE_KEY);
  if (stored === STORAGE_UNREACHABLE) return false;
  return (Number(stored) || 0) >= MAX_AUTH_BOUNCES;
}

/**
 * Called by a page that reached a definite verdict and will NOT navigate on.
 * That is the proof the chain terminated, so the next one starts from zero and
 * a user who logs out and back in never accumulates a stale budget.
 *
 * "Will not navigate on" is a precondition, not a description of intent, and it
 * is the easiest thing in this file to get wrong: clearing the budget and then
 * kicking off a fetch whose result may redirect somewhere else resets the
 * counter on every lap of the very loop it exists to catch. Call it only once
 * no further navigation can follow from this document — after the last verdict,
 * never before it.
 */
export function clearAuthRedirectBudget(): void {
  removeSessionValue(AUTH_BOUNCE_KEY);
}
