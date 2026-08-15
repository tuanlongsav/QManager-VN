"use client";

import { useEffect, useRef } from "react";
import { authFetch } from "@/lib/auth-fetch";
import {
  clearIndicatorCookie,
  isAuthNavigationInFlight,
  navigateForAuth,
} from "@/lib/session";

const CHECK_ENDPOINT = "/cgi-bin/quecmanager/auth/check.sh";

/** How often to ping check.sh while the dashboard is open (ms) */
const POLL_INTERVAL_MS = 10_000;

/**
 * How long the device must be continuously *unreachable* before we give up and
 * redirect to login. 90s is generous enough to survive normal slowness but
 * tight enough that a reboot (typically 30–60s) is caught once it finishes.
 */
const OFFLINE_THRESHOLD_MS = 90_000;

/**
 * Set once this hook has finished deciding, for the life of the document.
 *
 * This is NOT a second copy of the guard's in-flight latch — that one lives in
 * lib/session.ts and is the single answer to "is this document already leaving?".
 * This hook used to keep its own `loginNavigationStarted` alongside it, which is
 * how the two drifted apart: the private flag knew about redirects this hook
 * started and nothing else, so a 401 handled by authFetch left the poller
 * running, and a navigation this hook started was invisible to everyone else.
 * Ask isAuthNavigationInFlight() for that question now.
 *
 * What is left here is the question only this hook can answer: "has the poller
 * given up?". It covers the case the latch cannot — navigateForAuth returning
 * `refused`, where the redirect budget vetoed the hand-off, so NO navigation is
 * in flight and never will be. Without this, every remount of AppLayout would
 * restart a 10-second poll whose only possible outcome is another refusal.
 *
 * Module scope rather than a ref, because what it records is a fact about the
 * *document*, and the document outlives any single mount of AppLayout — a
 * remount during the tens of seconds a page load can take on this hardware
 * (OTA install, busy AT queue, lighttpd swapping /www) is perfectly ordinary.
 * One-way for the same reason the guard's latch is: there is no path back.
 */
let pollerStoodDown = false;

/**
 * Polls auth/check.sh every POLL_INTERVAL_MS while the dashboard is mounted.
 *
 * Three rules, and keeping them apart is the whole point of this hook:
 *
 * 1. **Session gone.** check.sh is the one CGI that sets `_SKIP_AUTH=1`
 *    (see scripts/www/cgi-bin/quecmanager/auth/check.sh), so it never answers
 *    401 — it answers 200 with `{"authenticated":false}`. Sessions expire on an
 *    absolute one-hour clock that `qm_validate_session` does not refresh, and
 *    /tmp/qmanager_sessions is wiped by every reboot, so this is the normal way
 *    a session ends. It has to be read out of the body; there is no status code
 *    to key off.
 *
 * 2. **Device unreachable.** Only a rejected fetch proves that. Any HTTP
 *    response at all — 500 from a CGI that hit a jq error, 404 while the OTA
 *    installer is swapping /www, 503 from lighttpd under load — proves the
 *    opposite: lighttpd is alive and answering. Treating those as "offline"
 *    would end in a forced logout of a session the device still considers
 *    perfectly valid, triggered by a bug that has nothing to do with auth.
 *
 * 3. **One redirect, ever, and it is not this hook's to make alone.** Every
 *    full-page auth navigation in the app goes through navigateForAuth() in
 *    lib/session.ts, which allows at most one per document no matter how many
 *    callers race — and on a dashboard running half a dozen pollers, a session
 *    that expires lands in all of them within the same second. The moment any
 *    of them starts the hand-off, here or in authFetch's 401 handler, this hook
 *    goes quiet for the life of the document: no more redirects, no more
 *    polling. See pollerStoodDown.
 */
export function useAutoLogout() {
  const offlineSinceRef = useRef<number | null>(null);

  useEffect(() => {
    // Remounted after this hook gave up, or while some other part of the app is
    // already navigating for an auth reason — either way there is nothing left
    // for this hook to decide, and every request it made from here would race a
    // document load that is already in progress.
    if (pollerStoodDown || isAuthNavigationInFlight()) return;

    let cancelled = false;
    let pollId: ReturnType<typeof setInterval> | null = null;
    let checkInFlight = false;

    /** Stand down permanently and take the poll off the event loop. */
    const stopPolling = () => {
      pollerStoodDown = true;
      if (pollId !== null) {
        clearInterval(pollId);
        pollId = null;
      }
    };

    /**
     * The single exit from this hook. Idempotent by construction, so it is safe
     * on every path that can reach it — the offline threshold, a session the
     * backend has declared dead, or a tick that resolved after the decision was
     * already taken. Clearing the interval alone would not be enough: a tick
     * already awaiting a response is not on the interval any more.
     */
    const goToLogin = (query = "") => {
      if (pollerStoodDown) return;

      // Stand down BEFORE anything else. Whatever navigateForAuth answers, this
      // hook is done: it has reached its verdict, and re-asking every 10s can
      // only produce the same one.
      stopPolling();

      // Unconditional, and deliberately not part of the navigation decision:
      // whether or not anyone navigates, this session is over — either the
      // backend said so or the device has been unreachable past the threshold.
      // A stale indicator cookie would have the dashboard gate wave the user
      // straight back into a page whose every request 401s.
      clearIndicatorCookie();

      // The guard decides whether the navigation actually happens; all three
      // answers are handled by doing nothing further:
      //   "started"    — the browser is leaving. There is no "after" here.
      //   "suppressed" — someone else is already handing this document over, or
      //                  we are somehow on /login/ already. Not an error, and
      //                  emphatically not something to show the user.
      //   "refused"    — the redirect budget vetoed it, meaning the gates have
      //                  been bouncing this tab and the loop breaker stopped it.
      //                  claimAuthRedirect has already logged the details. The
      //                  user stays on a dashboard whose requests will 401, and
      //                  authFetch's handler plus the gate's own escape link are
      //                  what put something clickable on screen — this hook has
      //                  no UI of its own to render a way out with.
      navigateForAuth(`/login/${query}`);
    };

    /** Advance the unreachable clock; log out once it runs past the threshold. */
    const noteUnreachable = () => {
      if (offlineSinceRef.current === null) {
        offlineSinceRef.current = Date.now();
        return;
      }
      if (Date.now() - offlineSinceRef.current >= OFFLINE_THRESHOLD_MS) {
        goToLogin("?reason=offline");
      }
    };

    const check = async () => {
      let response: Response;
      try {
        response = await authFetch(CHECK_ENDPOINT);
      } catch {
        noteUnreachable();
        return;
      }

      if (cancelled || pollerStoodDown) return;

      // A 401 anywhere in the app means authFetch has already asked the guard to
      // navigate to /login/. Stand down permanently rather than skipping this
      // one tick: every later poll would be another request racing that document
      // load, and the offline clock must not start ticking on requests that fail
      // because the page is being torn down.
      if (isAuthNavigationInFlight()) {
        stopPolling();
        return;
      }

      // We got bytes back, so the device is up. Reset the clock before looking
      // at *what* came back — reachability and session validity are separate
      // questions and a broken endpoint must not answer the first one.
      offlineSinceRef.current = null;

      // Non-2xx from check.sh means the endpoint itself is broken, not that the
      // session died. Leave the user where they are; the CGIs that actually
      // carry auth will 401 on their own if the session is really gone.
      if (!response.ok) return;

      let body: unknown;
      try {
        body = await response.json();
      } catch {
        // Unparseable body — same reasoning as a 5xx. jq lives on the Entware
        // volume at /opt, so an empty body is a plausible platform hiccup.
        return;
      }

      if (cancelled || pollerStoodDown) return;

      const authenticated = (body as { authenticated?: unknown } | null)
        ?.authenticated;

      // Only an explicit false counts. A missing field means the endpoint
      // answered something we do not understand, which is not grounds for
      // throwing the user out.
      if (authenticated === false) {
        goToLogin();
      }
    };

    const tick = () => {
      // A request that outlives its 10s slot must not get another stacked
      // behind it. A CGI blocked on the AT queue holds the connection open
      // without ever rejecting, and the browser's six-connections-per-origin
      // budget is shared with every other poller on the page. Skipping is also
      // the safe direction: the offline clock simply stops advancing, so a slow
      // device is never logged out for being slow.
      if (cancelled || pollerStoodDown || checkInFlight) return;
      checkInFlight = true;
      void check().finally(() => {
        checkInFlight = false;
      });
    };

    pollId = setInterval(tick, POLL_INTERVAL_MS);

    return () => {
      cancelled = true;
      if (pollId !== null) {
        clearInterval(pollId);
        pollId = null;
      }
    };
  }, []);
}
