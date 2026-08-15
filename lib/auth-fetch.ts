import { clearIndicatorCookie, navigateForAuth } from "@/lib/session";

/**
 * The in-flight latch used to live here as a module-scope `sessionRedirectInFlight`.
 * It moved to lib/session.ts when it stopped being a 401-only concern: the same
 * question ("is this document already leaving?") is asked by the auto-logout
 * poller, the gates and the OTA reboot, and three private copies of the answer
 * is how this bug kept coming back. Re-exported under its original name because
 * hooks/use-software-update.ts and hooks/use-auto-logout.ts import it from here.
 */
export { isSessionRedirectInFlight } from "@/lib/session";

/**
 * Thin fetch wrapper for the QManager CGI endpoints.
 *
 * Contract, stated exactly because its two halves pull in opposite directions:
 *
 * - The response is **always** returned, 401 included. Nothing is thrown and
 *   nothing is swallowed, so `resp.ok` and `resp.status` keep their ordinary
 *   meaning and a caller may read the 401 body (the auth CGI puts a machine
 *   code in it — see cgi_auth.sh `require_auth`).
 * - A 401 **additionally** clears the JS-readable indicator cookie and asks for
 *   a navigation to /login/.
 *
 * Because both halves happen, a returned `!ok` response is ambiguous on its own.
 * `isSessionRedirectInFlight()` is what disambiguates it.
 *
 * Cookies ride along automatically — no token injection needed.
 */
export async function authFetch(
  input: RequestInfo | URL,
  init?: RequestInit
): Promise<Response> {
  const response = await fetch(input, init);

  if (response.status === 401) {
    // Unconditional, and deliberately not part of the navigation decision: the
    // backend has just told us this session is dead, which is true whether or
    // not anyone navigates. Leaving the indicator cookie set would have the
    // dashboard gate wave the user straight back into a page that 401s.
    clearIndicatorCookie();

    // One navigation per document, decided in lib/session.ts, because a session
    // expiry does not arrive once. The dashboard runs half a dozen pollers in
    // parallel and they all get their 401 within the same second; before the
    // guard existed, each of those assignments aborted the /login/ load the
    // previous one had started, and the browser sat re-fetching a page it never
    // got to finish.
    //
    // What this code used to do instead, and why it could never work:
    //
    //     sessionRedirectInFlight = true;              // set, never read
    //     if (!window.location.pathname.startsWith("/login")) { ... }
    //
    // `window.location.pathname` is the address of the document currently on
    // screen. It does not change when a navigation *starts* — only when the new
    // document commits, which is the moment this one stops existing. So during
    // the entire window the guard needed to cover (href assigned, /login/ still
    // on the wire, this code still running and still getting 401s) the pathname
    // reads "/dashboard/", and the check waves every one of them through. A
    // location field can tell you where you are; nothing in it can tell you
    // where you are going. That is what the latch is for, and why it must be
    // read and not merely written.
    //
    // The pathname comparison survives inside navigateForAuth, in its honest
    // form: "am I already at the destination", which is the one question it can
    // answer, and which keeps a 401 on /login/ itself from reloading the page.
    navigateForAuth("/login/");
  }

  return response;
}
