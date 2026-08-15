"use client";

import { useCallback, useEffect, useState } from "react";
import {
  clearAuthRedirectBudget,
  clearIndicatorCookie,
  isLoggedIn,
  navigateForAuth,
} from "@/lib/session";

const CHECK_ENDPOINT = "/cgi-bin/quecmanager/auth/check.sh";
const LOGIN_ENDPOINT = "/cgi-bin/quecmanager/auth/login.sh";
const LOGOUT_ENDPOINT = "/cgi-bin/quecmanager/auth/logout.sh";
const PASSWORD_ENDPOINT = "/cgi-bin/quecmanager/auth/password.sh";
const SSH_PASSWORD_ENDPOINT = "/cgi-bin/quecmanager/auth/ssh_password.sh";

export { isLoggedIn, clearIndicatorCookie };

// ---------------------------------------------------------------------------
// Hook for login page (setup detection + login/setup actions)
// ---------------------------------------------------------------------------

export type LoginStatus = "loading" | "ready" | "setup_required";

/**
 * Result of a login-page action.
 *
 * The auth CGI answers failures with two separate fields: `error` is a stable
 * machine code ("invalid_password", "rate_limited" — see auth/login.sh) and
 * `detail` is an English sentence meant for a human reading a curl dump. They
 * are kept apart here instead of collapsed into one string, because the UI
 * layer has to translate, and only the code is safe to match on — the sentence
 * would silently stop matching the day someone reworded it in login.sh.
 *
 * `detail` is carried through anyway rather than dropped: it never reaches the
 * screen, but it is what a maintainer wants in the browser console when a code
 * shows up that the UI has no translation for.
 *
 * The standalone helpers further down (setupPassword, changePassword,
 * changeSSHPassword) keep the older flattened `{ error }` shape — their callers
 * render that string directly and have no translation table to key a code into.
 */
export interface LoginResult {
  success: boolean;
  /** Backend `error` code, or a client-side sentinel such as "connection_failed". */
  code?: string;
  /** Backend `detail` sentence, English. Diagnostics only — never render it. */
  detail?: string;
  /** Seconds to wait, present only on a 429. Drives the login countdown. */
  retry_after?: number;
}

export function useLogin() {
  const [status, setStatus] = useState<LoginStatus>("loading");

  useEffect(() => {
    // If already logged in, redirect to dashboard.
    //
    // This half is the reason a single bad verdict on the dashboard side turned
    // into an infinite loop rather than one wrong page: the two gates redirect
    // at each other. The budget inside navigateForAuth caps how many times that
    // can happen; when the cap is hit it answers "refused" and we deliberately
    // fall through to the setup check below, so the tab settles on a page the
    // user can actually use rather than on a spinner.
    if (isLoggedIn() && navigateForAuth("/dashboard/") !== "refused") {
      return;
    }

    // Check if first-time setup is needed
    fetch(CHECK_ENDPOINT)
      .then((r) => r.json())
      .then((data) => {
        if (data.setup_required) {
          // NOT a terminal state, and this is where the budget used to be
          // wrongly cleared. LoginComponent reacts to this status by navigating
          // on to /setup/, so the chain is still running — clearing here reset
          // the counter on every lap of the exact /login/ -> /setup/ -> /login/
          // ping-pong the counter exists to catch, and the loop breaker could
          // never reach three.
          setStatus("setup_required");
          return;
        }
        // Terminal: the login form is what renders next, and a rendered form is
        // something the user can act on. "The chain ended" means the user has
        // ARRIVED somewhere usable — not that a page started loading, and not
        // that this document happens to have skipped one redirect on its way to
        // issuing another.
        clearAuthRedirectBudget();
        setStatus("ready");
      })
      .catch(() => {
        // Backend unreachable on a fresh install likely means setup hasn't
        // completed yet (e.g. lighttpd started before qmanager-setup).
        // Default to setup_required so onboarding isn't silently skipped.
        // Same reasoning as the branch above: this hands off to /setup/, so the
        // budget stays where it is.
        setStatus("setup_required");
      });
  }, []);

  const login = useCallback(
    async (password: string): Promise<LoginResult> => {
      try {
        const resp = await fetch(LOGIN_ENDPOINT, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ password }),
        });
        const data = await resp.json();

        if (data.success) {
          // Cookie is set by the backend — just redirect.
          //
          // Uncounted, unlike the gate hops: reaching this line took a password
          // and a click. A cycle through it would need the user to retype the
          // password on every lap, which makes it a bad login experience but not
          // the runaway this budget guards against — and spending budget here
          // could see a correct password answered with a refusal and a form that
          // just sits there. The latch still applies, so this never cancels a
          // navigation already on the wire.
          navigateForAuth("/dashboard/", { countsAsBounce: false });
          return { success: true };
        }

        if (data.error === "setup_required") {
          setStatus("setup_required");
          return { success: false, code: "setup_required" };
        }

        return {
          success: false,
          code: data.error,
          detail: data.detail,
          retry_after: data.retry_after,
        };
      } catch {
        // Not a backend code: the request never produced parseable JSON.
        return {
          success: false,
          code: "connection_failed",
          detail: "Connection failed",
        };
      }
    },
    []
  );

  const setup = useCallback(
    async (password: string, confirm: string): Promise<LoginResult> => {
      try {
        const resp = await fetch(LOGIN_ENDPOINT, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ password, confirm }),
        });
        const data = await resp.json();

        if (data.success) {
          // Same reasoning as login() above — user-initiated, so uncounted.
          navigateForAuth("/dashboard/", { countsAsBounce: false });
          return { success: true };
        }

        return {
          success: false,
          code: data.error,
          detail: data.detail,
        };
      } catch {
        return {
          success: false,
          code: "connection_failed",
          detail: "Connection failed",
        };
      }
    },
    []
  );

  return { status, login, setup };
}

// ---------------------------------------------------------------------------
// Standalone setup (used by onboarding wizard — does NOT redirect on success)
// ---------------------------------------------------------------------------

/**
 * Creates the initial password and session without redirecting.
 * Used by the onboarding wizard so it can advance steps instead of
 * immediately sending the user to the dashboard.
 */
export async function setupPassword(
  password: string,
  confirm: string
): Promise<{ success: boolean; error?: string }> {
  try {
    const resp = await fetch(LOGIN_ENDPOINT, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ password, confirm }),
    });
    const data = await resp.json();

    if (data.success) {
      return { success: true };
    }

    return {
      success: false,
      error: data.detail || data.error || "Setup failed",
    };
  } catch {
    return { success: false, error: "Connection failed" };
  }
}

// ---------------------------------------------------------------------------
// Actions (used by sidebar menu / change password dialog)
// ---------------------------------------------------------------------------

export async function logout(): Promise<void> {
  try {
    await fetch(LOGOUT_ENDPOINT, { method: "POST" });
  } catch {
    // Ignore network errors on logout
  } finally {
    clearIndicatorCookie();
    // Uncounted for the same reason as a successful login: a menu item the user
    // clicked cannot be a lap of an automatic loop. Routed through the guard
    // anyway so it defers to a navigation already in flight — a logout raced by
    // authFetch's 401 hand-off is two documents fetched for one destination.
    navigateForAuth("/login/", { countsAsBounce: false });
  }
}

export async function changePassword(
  current: string,
  newPassword: string
): Promise<{ success: boolean; error?: string }> {
  try {
    const resp = await fetch(PASSWORD_ENDPOINT, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        current_password: current,
        new_password: newPassword,
      }),
    });
    const data = await resp.json();

    if (data.success) {
      clearIndicatorCookie();
      // The backend invalidated the session along with the password, so this is
      // a forced re-login rather than a gate decision — uncounted, latched.
      navigateForAuth("/login/", { countsAsBounce: false });
      return { success: true };
    }

    return {
      success: false,
      error: data.detail || data.error || "Password change failed",
    };
  } catch {
    return { success: false, error: "Connection failed" };
  }
}

// ---------------------------------------------------------------------------
// SSH password management
// ---------------------------------------------------------------------------

export async function changeSSHPassword(
  currentPassword: string,
  newPassword: string,
  confirmPassword: string
): Promise<{ success: boolean; error?: string }> {
  try {
    const resp = await fetch(SSH_PASSWORD_ENDPOINT, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        current_password: currentPassword,
        new_password: newPassword,
        confirm_password: confirmPassword,
      }),
    });
    const data = await resp.json();

    if (data.success) {
      return { success: true };
    }

    return {
      success: false,
      error: data.detail || data.error || "SSH password change failed",
    };
  } catch {
    return { success: false, error: "Connection failed" };
  }
}
