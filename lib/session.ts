/** JS-readable login indicator set by the backend alongside HttpOnly session cookie. */
const LOGIN_INDICATOR = "qm_logged_in";
const REBOOT_SESSION_KEY = "qm_rebooting";

function getCookieValue(name: string): string | null {
  if (typeof document === "undefined") return null;
  const prefix = `${name}=`;
  for (const part of document.cookie.split(";")) {
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
  document.cookie = `${LOGIN_INDICATOR}=; Path=/; Max-Age=0`;
}

/** Call before navigating to /reboot/ so the countdown page and OTA worker sync. */
export function prepareForReboot(): void {
  sessionStorage.setItem(REBOOT_SESSION_KEY, "1");
  clearIndicatorCookie();
}
