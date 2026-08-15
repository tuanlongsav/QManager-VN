"use client";

import { useEffect, useState } from "react";
import {
  clearAuthRedirectBudget,
  isLoggedIn,
  navigateForAuth,
} from "@/lib/session";
import { OnboardingWizard } from "@/components/onboarding/onboarding-wizard";
import { Spinner } from "@/components/ui/spinner";
import { useT } from "@/hooks/use-i18n";

// =============================================================================
// /setup — First-time onboarding wizard route
// =============================================================================
// Guards:
//   - Already logged in + onboarding completed → redirect /dashboard/
//   - setup_required is false (password already set, not logged in) → /login/
// Renders OnboardingWizard when setup_required is confirmed.
//
// Both guards are auth gates in the same graph as /dashboard/ and /login/, so
// both go through navigateForAuth, which spends the shared redirect budget and
// respects the shared in-flight latch. This route used to redirect outside the
// budget, which meant the loop breaker could only see two of the three vertices:
// with lighttpd down, /login/ hands a user here on a failed check.sh and guard 1
// hands them straight back, a cycle the budget never counted. Any new redirect
// added below has to go through navigateForAuth too, or it reopens that hole.
// =============================================================================

const CHECK_ENDPOINT = "/cgi-bin/quecmanager/auth/check.sh";

export default function SetupPage() {
  const { t } = useT();
  const [ready, setReady] = useState(false);
  // Destination of a redirect the budget refused, or null. Offering it as a
  // link rather than retrying is what ends the loop, and it keeps the user one
  // click from the page they were headed for.
  const [blockedHref, setBlockedHref] = useState<string | null>(null);

  useEffect(() => {
    // Guard 1: already logged in
    if (isLoggedIn()) {
      if (navigateForAuth("/dashboard/") !== "refused") return;
      // Unlike /login/, this page cannot fall through and render itself when the
      // budget is spent: the wizard is destructive-looking for someone who is
      // already set up and signed in, and it would invite them to redo
      // onboarding. Stop on a link instead.
      setBlockedHref("/dashboard/");
      return;
    }

    // Guard 2: confirm setup_required via backend (retry on failure —
    // during first boot lighttpd may start before the backend is ready)
    let attempt = 0;
    const maxRetries = 3;
    const retryDelay = 1500; // ms

    function checkSetup() {
      fetch(CHECK_ENDPOINT)
        .then((r) => r.json())
        .then((data) => {
          if (!data.setup_required) {
            // Password already set — go to normal login
            if (navigateForAuth("/login/") === "refused") {
              setBlockedHref("/login/");
            }
            return;
          }
          // Terminal: the wizard renders next and nothing else will navigate
          // away from this document, so the user has arrived somewhere they can
          // act. That — arrival, not departure — is what clears the budget.
          clearAuthRedirectBudget();
          setReady(true);
        })
        .catch(() => {
          attempt++;
          if (attempt < maxRetries) {
            setTimeout(checkSetup, retryDelay);
            return;
          }
          // Backend still unreachable after retries — show wizard anyway.
          // On a fresh install this is the safe default. It is also a terminal
          // state — the wizard is on screen and no further navigation follows —
          // so the chain ended here just as surely as a confirmed
          // setup_required did.
          clearAuthRedirectBudget();
          setReady(true);
        });
    }

    checkSetup();
  }, []);

  if (blockedHref) {
    return (
      <div className="flex min-h-svh flex-col items-center justify-center gap-3 bg-background px-6 text-center">
        <p className="text-sm text-muted-foreground">
          {t("authGate.sessionUnconfirmed")}
        </p>
        <a
          href={blockedHref}
          className="text-sm font-medium text-primary underline underline-offset-4"
        >
          {blockedHref === "/dashboard/"
            ? t("authGate.goToDashboard")
            : t("authGate.goToSignIn")}
        </a>
      </div>
    );
  }

  if (!ready) {
    return (
      <div className="flex min-h-svh items-center justify-center bg-background">
        <Spinner className="size-6 text-muted-foreground" />
      </div>
    );
  }

  return <OnboardingWizard />;
}
