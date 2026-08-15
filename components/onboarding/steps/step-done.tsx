"use client";

import { useEffect, useRef, useState } from "react";
import { CheckIcon } from "lucide-react";
import { Button } from "@/components/ui/button";
import { navigateForAuth } from "@/lib/session";

// =============================================================================
// StepDone — Onboarding step 6: completion screen + confetti
// =============================================================================

// Brand-derived confetti colors (primary blue-indigo palette)
const CONFETTI_COLORS = ["#4f46e5", "#6366f1", "#818cf8", "#a5b4fc", "#c7d2fe", "#e0e7ff"];

export function StepDone() {
  const prefersReducedMotion =
    typeof window !== "undefined" &&
    window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  const [show, setShow] = useState(prefersReducedMotion);
  const dashboardBtnRef = useRef<HTMLAnchorElement>(null);

  useEffect(() => {
    if (prefersReducedMotion) return;
    const timer = setTimeout(() => setShow(true), 80);
    return () => clearTimeout(timer);
  }, [prefersReducedMotion]);

  // Confetti burst on mount
  useEffect(() => {
    if (prefersReducedMotion) return;

    let cancelled = false;

    const fire = async () => {
      const confetti = (await import("canvas-confetti")).default;
      if (cancelled) return;

      // Center burst
      confetti({
        particleCount: 70,
        spread: 55,
        origin: { x: 0.5, y: 0.45 },
        colors: CONFETTI_COLORS,
        scalar: 0.85,
        gravity: 1.1,
      });

      // Side bursts after a short delay
      setTimeout(() => {
        if (cancelled) return;
        confetti({
          particleCount: 30,
          spread: 50,
          angle: 65,
          origin: { x: 0.15, y: 0.5 },
          colors: CONFETTI_COLORS,
          scalar: 0.8,
        });
        confetti({
          particleCount: 30,
          spread: 50,
          angle: 115,
          origin: { x: 0.85, y: 0.5 },
          colors: CONFETTI_COLORS,
          scalar: 0.8,
        });
      }, 180);
    };

    const timer = setTimeout(fire, 300);
    return () => {
      cancelled = true;
      clearTimeout(timer);
    };
  }, [prefersReducedMotion]);

  useEffect(() => {
    dashboardBtnRef.current?.focus();
  }, []);

  // "Go to Dashboard" is an AUTH navigation, not a cosmetic one: /dashboard/ is
  // the dashboard auth gate, one of the vertices the redirect budget in
  // lib/session.ts exists to bound. Onboarding hands off to it at the exact
  // moment the session state is freshest and least settled — the wizard has just
  // written config the gate is about to re-read — so this is precisely the edge
  // that must be visible to the loop breaker rather than a raw location
  // assignment racing whatever else the page has in flight.
  //
  // It SPENDS budget (the countsAsBounce default). lib/session.ts's own rule for
  // opting out is "provably cannot be part of an auth cycle because it does not
  // lead back to a gate", and /dashboard/ is a gate: if it misreads the session
  // it hands straight on to /login/, which on this device can hand on again to
  // /setup/ — the wizard we just came out of. That is a cycle, so it gets
  // counted. The escape-hatch carve-out (countsAsBounce:false) is for links a
  // *refused* gate renders as a last resort, not for ordinary forward progress.
  //
  // Rendering this as a real <a href> is what makes the refusal survivable, and
  // it costs nothing: the element is a link either way. On "started"/"suppressed"
  // the guard owns the navigation and we cancel the browser's default; on
  // "refused" we let the default through, so the user's click still lands them on
  // the dashboard. That is legitimate rather than a hole in the budget — a
  // human-initiated navigation cannot be the lap of a machine loop, and it is the
  // same escape valve the refused gates offer. It also means middle-click,
  // open-in-new-tab and a failed JS bundle all behave sensibly.
  const handleGoToDashboard = (e: React.MouseEvent<HTMLAnchorElement>) => {
    // Modifier and non-primary clicks open a new tab or window. Those do not
    // navigate THIS document, so there is nothing for the guard to protect — and
    // calling it anyway would be actively wrong: it would send the *current* tab
    // to /dashboard/ while preventDefault swallowed the new tab the user asked
    // for. Hand them straight back to the browser.
    if (
      e.defaultPrevented ||
      e.button !== 0 ||
      e.metaKey ||
      e.ctrlKey ||
      e.shiftKey ||
      e.altKey
    ) {
      return;
    }
    const outcome = navigateForAuth("/dashboard/");
    if (outcome !== "refused") e.preventDefault();
  };

  return (
    <div className="flex flex-col items-center gap-6 text-center py-2">
      {/* Animated checkmark */}
      <div
        className="flex size-16 items-center justify-center rounded-full bg-primary/10 transition-[opacity,transform] duration-500"
        style={{
          opacity: show ? 1 : 0,
          transform: show ? "scale(1)" : "scale(0.6)",
        }}
      >
        <CheckIcon className="size-8 text-primary stroke-[2.5]" />
      </div>

      <div className="flex flex-col gap-2">
        <h2 className="text-2xl font-semibold tracking-tight">You&apos;re all set!</h2>
        <p className="text-sm text-muted-foreground max-w-xs leading-relaxed">
          QManager is ready. Everything you configured is active, and you can
          change any setting anytime from the sidebar.
        </p>
      </div>

      {/* Tip callout */}
      <div className="w-full rounded-xl bg-muted/60 border border-border px-4 py-3 text-left">
        <p className="text-xs text-muted-foreground leading-relaxed">
          <span className="font-medium text-foreground">Pro tip:</span> Visit{" "}
          <span className="font-medium">Cellular › Band Locking</span> to
          fine-tune signal strength, or{" "}
          <span className="font-medium">Monitoring › Watchdog</span> to set up
          automatic recovery.
        </p>
      </div>

      <Button asChild className="w-full" size="lg">
        <a ref={dashboardBtnRef} href="/dashboard/" onClick={handleGoToDashboard}>
          Go to Dashboard
        </a>
      </Button>
    </div>
  );
}
