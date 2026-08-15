"use client";

import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import { motion, AnimatePresence } from "motion/react";
import { Spinner } from "@/components/ui/spinner";
import {
  readStorageValue,
  removeStorageValue,
  STORAGE_UNREACHABLE,
} from "@/lib/browser-storage";
import {
  isAuthRedirectBudgetExhausted,
  navigateForAuth,
  REBOOT_SESSION_KEY,
} from "@/lib/session";
import { cn } from "@/lib/utils";

const TOTAL_SECONDS = 70;
const POLL_START_AT = 35; // seconds remaining when polling begins
const POLL_INTERVAL = 5000; // ms between polls
const REDIRECT_DELAY = 3000; // ms to wait after device responds before redirecting
const CHECK_ENDPOINT = "/cgi-bin/quecmanager/auth/check.sh";
const OVERTIME_ESCAPE_AT = -180; // show escape link after 3 minutes past zero

// SVG ring geometry
const RING_SIZE = 120;
const RING_RADIUS = 52;
const RING_CIRCUMFERENCE = 2 * Math.PI * RING_RADIUS;
const RING_STROKE = 5;

// Client-only marker: `false` while prerendering, `true` once mounted in a
// browser. The value never changes afterwards, so the subscription is a no-op.
const subscribeNoop = () => () => {};
const getHydrated = () => true;
const getServerHydrated = () => false;

/**
 * What this document can honestly say about "was a reboot actually requested?".
 *
 * Three states, not two, and the third is the whole point. The marker lives in
 * sessionStorage, and a browser that denies this document storage (a WebView, a
 * sandboxed iframe, Safari with cookies blocked) does not report an empty store
 * — reading the `sessionStorage` property itself throws. Folding that case into
 * "absent" would mean the marker can never be written *and* never be read, so
 * /reboot/ would bounce every single visitor in those browsers away from the one
 * page that explains why their device just went offline.
 */
type RebootMarker =
  /** The marker is there: a reboot was requested from this tab. Show the countdown. */
  | "present"
  /** Storage works and the marker is not set: somebody typed /reboot/ by hand. */
  | "absent"
  /** No usable storage, so the question is unanswerable — see below for why we fail open. */
  | "unreadable";

interface Phase {
  label: string;
  segment: number; // 1-indexed active segment
}

function getPhase(remaining: number): Phase {
  if (remaining > 47) return { label: "Shutting down...", segment: 1 };
  if (remaining > 23) return { label: "Restarting services...", segment: 2 };
  if (remaining > 0) return { label: "Almost ready...", segment: 3 };
  return { label: "Reconnecting \u2014 taking longer than usual...", segment: 3 };
}

export function RebootCountdown() {
  // Snapshot the direct-access marker once, when the state is created. It has to
  // be a snapshot: the effect below consumes the key, and re-reading it would
  // flip the guard back off mid-countdown.
  //
  // The read goes through lib/browser-storage rather than touching
  // sessionStorage directly, and that is not tidiness — it is the crash fix. A
  // bare `sessionStorage.getItem` here throws SecurityError in a storage-blocked
  // document, and a throw inside a useState INITIALIZER happens during render, so
  // React has no tree to fall back to: the page goes blank. On a headless modem
  // whose only UI is this page, blank means SSH. `typeof window` did not help,
  // because in those browsers `window` exists and it is the storage property
  // lookup that fails. Same crash that was already fixed in
  // components/layout/unsupported-model-banner.tsx; this was the second copy.
  const [marker] = useState<RebootMarker>(() => {
    const stored = readStorageValue("session", REBOOT_SESSION_KEY);
    if (stored === STORAGE_UNREACHABLE) return "unreadable";
    return stored === null ? "absent" : "present";
  });

  // sessionStorage doesn't exist during the static-export prerender, so the
  // server snapshot is `false` and the first paint stays empty — matching the
  // prerendered HTML. The real guard takes over right after hydration. Same
  // idiom as the login gate in app-layout.tsx.
  const hydrated = useSyncExternalStore(
    subscribeNoop,
    getHydrated,
    getServerHydrated
  );

  // FAIL OPEN on "unreadable". The guard exists to stop a stray bookmark from
  // showing a fake countdown — a cosmetic concern. Being wrong the other way is
  // not cosmetic: a user whose browser blocks storage would be bounced off every
  // reboot they ever trigger, and bounced to a page served by a device that is at
  // that moment powering down, so the bounce itself fails too. Show the countdown
  // when we cannot tell. Note this also covers callers other than nav-user —
  // the OTA updater and the MBN/IP-passthrough cards all land here, and
  // prepareForReboot() could not have written a marker for any of them either.
  const verified = hydrated && marker !== "absent";

  const [remaining, setRemaining] = useState(TOTAL_SECONDS);
  const pollingRef = useRef(false);
  const remainingRef = useRef(TOTAL_SECONDS);

  // How the hand-off to /login/ went, once the device answers again. "pending"
  // until the poller commits to one, then terminal. Every repeating timer in this
  // component is gated on it, because navigateForAuth's contract is that a caller
  // holding a timer stands down *permanently* once the answer is in — skipping a
  // tick is not enough, the next tick has exactly the same problem.
  const [handoff, setHandoff] = useState<"pending" | "leaving" | "refused">(
    "pending"
  );

  // Direct-access guard: only show countdown if a reboot was actually triggered
  useEffect(() => {
    if (!hydrated) return;
    if (marker === "absent") {
      // This bounce IS an auth navigation, and calling it one is not a
      // formality. The old target "/" looks like a neutral home page, but
      // app/page.tsx renders the very same LoginComponent as /login/ — gate
      // included — and that gate hands a fresh install on to /setup/ and a
      // logged-in user on to /dashboard/. So the destination was always a vertex
      // of the graph the redirect budget bounds; only the URL disguised it. It is
      // now spelled /login/ to match, which also makes it identical to every
      // other auth hand-off in the app (authFetch's 401 path, useAutoLogout, and
      // the overtime escape link at the bottom of this very file). Same rendered
      // page, honest name, and one destination instead of two aliases for the
      // isCurrentDocument check to have to reason about.
      //
      // Full budget price: /login/ can hand on again, so it is exactly the kind
      // of edge an uncounted hop would hide. A "refused" answer is handled at
      // render time below, where the budget can be consulted for free before
      // anything is committed.
      navigateForAuth("/login/");
      return;
    }
    // Best-effort: on an "unreadable" store there is nothing to remove, and the
    // helper simply does nothing rather than throwing on the way out.
    removeStorageValue("session", REBOOT_SESSION_KEY);

    // Tell the OTA worker (if any) that the static reboot page has loaded
    // so it can stop waiting and fire the reboot syscall. Harmless on
    // non-OTA reboots — the worker simply isn't watching.
    fetch("/cgi-bin/quecmanager/system/update.sh?action=reboot_ack", {
      keepalive: true,
    }).catch(() => {});
  }, [hydrated, marker]);

  // Would that bounce to "/" be vetoed? Asked at render, where it costs nothing
  // (isAuthRedirectBudgetExhausted only reads the counter), because the effect
  // above runs *after* the paint — without this the refused case would render
  // `null` forever and leave the user staring at a blank page with no way out.
  // Same idiom as the setup-gate branch in components/auth/login-component.tsx.
  const bounceRefused =
    hydrated && marker === "absent" && isAuthRedirectBudgetExhausted();

  // Keep ref in sync so the polling effect can read it without re-subscribing
  useEffect(() => {
    remainingRef.current = remaining;
  }, [remaining]);

  // Countdown timer — only start after guard passes. Stops for good once the
  // hand-off is decided: on "leaving" the document is on its way out and a
  // ticking clock is just work racing a load, on "refused" the number is
  // meaningless because nothing is going to happen at zero.
  useEffect(() => {
    if (!verified || handoff !== "pending") return;
    const id = setInterval(() => {
      setRemaining((prev) => prev - 1);
    }, 1000);
    return () => clearInterval(id);
  }, [verified, handoff]);

  // Device health polling — single interval, checks remainingRef each tick
  useEffect(() => {
    if (!verified || handoff !== "pending") return;
    const id = setInterval(async () => {
      // Don't poll until countdown reaches the threshold
      if (remainingRef.current > POLL_START_AT) return;
      if (pollingRef.current) return;
      pollingRef.current = true;
      try {
        const res = await fetch(CHECK_ENDPOINT);
        if (res.ok) {
          clearInterval(id);
          // Wait a few seconds for the poller to initialize
          // so the dashboard isn't blank on first load
          setTimeout(() => {
            // /login/ is an auth gate — it can hand a logged-in user on to
            // /dashboard/, or a fresh install on to /setup/ — so this is a real
            // edge of the auth graph, and before this fix it was a raw
            // window.location assignment the loop breaker could not see. It
            // spends budget for that reason: lib/session.ts only exempts a
            // destination that provably does not lead back to a gate, and this
            // one is a gate.
            //
            // The reboot cleared /tmp/qmanager_sessions, so the session really is
            // gone and /login/ really is where this user belongs; if the gate
            // there disagrees, that disagreement is exactly the ping-pong the
            // budget exists to stop, and stopping it here is worth more than
            // saving one hop.
            const outcome = navigateForAuth("/login/");
            // "started" and "suppressed" are the same instruction to us: the
            // browser is leaving (whether because of this call or an earlier
            // one), so stand down and touch nothing else. "suppressed" is not an
            // error and gets no message. "refused" means the navigation will
            // never happen, so surface the escape link immediately instead of
            // making the user wait out the three-minute overtime timer for it.
            setHandoff(outcome === "refused" ? "refused" : "leaving");
          }, REDIRECT_DELAY);
          return;
        }
      } catch {
        // Device still offline
      }
      pollingRef.current = false;
    }, POLL_INTERVAL);

    return () => clearInterval(id);
  }, [verified, handoff]);

  // Direct visit with the bounce vetoed: the redirect is never coming, so render
  // something the user can click. A plain <a> is the escape hatch the budget
  // deliberately leaves open — a human click cannot be a lap of a machine loop.
  if (bounceRefused) {
    return (
      <div className="flex min-h-svh flex-col items-center justify-center gap-2 bg-background p-6 text-center">
        <p className="text-[15px] font-medium text-foreground">
          No reboot in progress
        </p>
        <p className="text-[13px] text-muted-foreground">
          This page only appears while the device is restarting.
        </p>
        <a
          href="/login/"
          className="mt-2 text-xs text-muted-foreground underline underline-offset-4 transition-colors hover:text-foreground"
        >
          Go to QManager
        </a>
      </div>
    );
  }

  // Don't render until guard passes
  if (!verified) return null;

  const phase = getPhase(remaining);
  const isOvertime = remaining <= 0;
  const displaySeconds = Math.max(0, remaining);
  // Normally the escape link is a last resort after three minutes of silence.
  // A refused hand-off promotes it to the only way out, so show it at once.
  const showEscape = remaining <= OVERTIME_ESCAPE_AT || handoff === "refused";

  // Ring progress: 0 at start → full at 0 remaining
  const progress = Math.min(1, (TOTAL_SECONDS - remaining) / TOTAL_SECONDS);
  const dashOffset = RING_CIRCUMFERENCE * (1 - progress);

  return (
    <div className="flex min-h-svh flex-col items-center justify-center bg-background p-6">
      <motion.div
        initial={{ opacity: 0, y: 6 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ duration: 0.5, ease: [0.25, 1, 0.5, 1] }}
        className="flex flex-col items-center"
      >
      {/* Card */}
      <div className="flex flex-col items-center gap-6 rounded-xl border bg-card px-12 py-10 shadow-sm max-w-[340px] w-full">
        {/* Logo */}
        <img
          src="/qmanager-logo.svg"
          alt="QManager"
          className="size-9"
        />

        {/* Progress ring with countdown */}
        <div
          role="timer"
          aria-label={
            isOvertime
              ? "Reconnecting, taking longer than usual"
              : `${displaySeconds} seconds remaining`
          }
          className="relative"
          style={{ width: RING_SIZE, height: RING_SIZE }}
        >
          <svg
            width={RING_SIZE}
            height={RING_SIZE}
            viewBox={`0 0 ${RING_SIZE} ${RING_SIZE}`}
            className="-rotate-90"
            aria-hidden="true"
          >
            {/* Background track */}
            <circle
              cx={RING_SIZE / 2}
              cy={RING_SIZE / 2}
              r={RING_RADIUS}
              fill="none"
              className="stroke-muted/20"
              strokeWidth={RING_STROKE}
            />
            {/* Progress arc */}
            <circle
              cx={RING_SIZE / 2}
              cy={RING_SIZE / 2}
              r={RING_RADIUS}
              fill="none"
              className="stroke-primary"
              strokeWidth={RING_STROKE}
              strokeDasharray={RING_CIRCUMFERENCE}
              strokeDashoffset={dashOffset}
              strokeLinecap="round"
              style={{
                transition: "stroke-dashoffset 1s linear",
                filter:
                  "drop-shadow(0 0 6px color-mix(in oklch, var(--primary) 30%, transparent))",
              }}
            />
          </svg>

          {/* Countdown number */}
          <div className="absolute inset-0 flex flex-col items-center justify-center">
            {isOvertime ? (
              <Spinner className="size-6" />
            ) : (
              <>
                <span className="text-[32px] font-semibold leading-none tracking-tight text-foreground tabular-nums">
                  {displaySeconds}
                </span>
                <span className="mt-1 text-[10px] uppercase tracking-widest text-muted-foreground">
                  sec
                </span>
              </>
            )}
          </div>
        </div>

        {/* Phase message */}
        <div className="text-center min-h-[48px] flex flex-col items-center justify-center">
          {/* Visually hidden live region for screen reader phase announcements */}
          <p className="sr-only" aria-live="polite" aria-atomic="true">
            {phase.label}
          </p>
          <AnimatePresence mode="wait">
            <motion.div
              key={phase.label}
              initial={{ opacity: 0, y: 4 }}
              animate={{ opacity: 1, y: 0 }}
              exit={{ opacity: 0, y: -4 }}
              transition={{ duration: 0.2 }}
              aria-hidden="true"
            >
              <p className="text-[15px] font-medium text-foreground">
                {phase.label}
              </p>
              <p className="mt-1 text-[13px] text-muted-foreground">
                {isOvertime
                  ? "The device is still restarting"
                  : "Your device will be back online shortly"}
              </p>
            </motion.div>
          </AnimatePresence>
        </div>

        {/* Segmented progress bar */}
        <div className="flex w-full gap-1.5">
          {[1, 2, 3].map((seg) => (
            <div
              key={seg}
              className={cn(
                "h-[3px] flex-1 rounded-full transition-colors duration-500",
                seg < phase.segment
                  ? "bg-primary"
                  : seg === phase.segment
                    ? "bg-primary/60"
                    : "bg-muted/30"
              )}
            />
          ))}
        </div>
      </div>

      {/* Brand text below card */}
      <p className="mt-5 text-xs text-muted-foreground/40">QManager</p>

      {/* Overtime escape — appears after 3 minutes with no response */}
      {showEscape && (
        <a
          href="/login/"
          className="mt-3 text-xs text-muted-foreground underline underline-offset-4 transition-colors hover:text-foreground"
        >
          Device may need manual attention — go to login
        </a>
      )}
      </motion.div>
    </div>
  );
}
