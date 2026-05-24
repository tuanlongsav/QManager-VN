/**
 * SMS sender formatting helpers — display layer only.
 *
 * VN telcos send service messages from text-only sender IDs (no phone number),
 * e.g. "VIETTEL", "VINAPHONE", "MOBIFONE", "MyVNPT". These should display with
 * an explicit "Brand" tag so the user knows it's an SMS-A2P from a carrier
 * service and not a personal contact.
 *
 * Phone-number senders should display in local format (0xxx) for VN audience
 * — international format (+84xxx) is harder to scan at a glance. We only
 * convert when the sender starts with +84 or 84 to avoid messing up
 * international contacts.
 */

/** Brand sender heuristic: alphanumeric-only, no digits-only, length 2-11. */
const BRAND_SENDER_RE = /^[A-Za-z][A-Za-z0-9._-]{1,10}$/;

/** Known VN telco / service brand senders (case-insensitive). */
const KNOWN_VN_BRANDS = new Set([
  "VIETTEL",
  "VIETTELMOBILE",
  "VINAPHONE",
  "VNPT",
  "MYVNPT",
  "MOBIFONE",
  "VIETNAMOBILE",
  "WINTEL",
  "REDDI",
  "ITELECOM",
  // Common service brands frequently messaging Vietnamese users
  "MOMO",
  "ZALOPAY",
  "VIETCOMBANK",
  "TECHCOMBANK",
  "BIDV",
  "VPBANK",
  "ACB",
  "SACOMBANK",
  "AGRIBANK",
  "MBBANK",
  "TPBANK",
  "VIB",
  "SHB",
  "HDBANK",
  "ZALO",
  "FACEBOOK",
  "GRAB",
  "SHOPEE",
  "LAZADA",
  "TIKI",
  "BEAMIN",
  "SAMSUNG",
  "APPLE",
  "GOOGLE",
]);

/**
 * Classify a sender string as either "brand" (alphanumeric, no leading digit)
 * or "phone" (digits, optionally + prefix).
 */
export function classifySender(sender: string | null | undefined): "brand" | "phone" | "unknown" {
  if (!sender) return "unknown";
  const trimmed = sender.trim();
  if (!trimmed) return "unknown";
  if (/^\+?\d+$/.test(trimmed)) return "phone";
  if (BRAND_SENDER_RE.test(trimmed)) return "brand";
  return "unknown";
}

/** Whether a brand sender is a known VN carrier or major VN service. */
export function isKnownVnBrand(sender: string): boolean {
  return KNOWN_VN_BRANDS.has(sender.toUpperCase());
}

/**
 * Format a phone number for display. For VN audience:
 *   "+84901234567" → "0901234567"
 *   "84901234567"  → "0901234567"
 *   "0901234567"   → "0901234567"  (already local)
 *   "+1234567890"  → "+1234567890" (foreign number, leave alone)
 *
 * Brand senders pass through unchanged — only phone-number senders are
 * normalized to local format.
 */
export function formatPhoneDisplay(sender: string | null | undefined): string {
  if (!sender) return "";
  const trimmed = sender.trim();
  if (!trimmed) return "";

  // VN: +84xxxxxxxxxx (10-11 digits after country code) → 0xxxxxxxxxx
  const vnMatch = trimmed.match(/^\+?84(\d{9,10})$/);
  if (vnMatch) {
    return "0" + vnMatch[1];
  }

  return trimmed;
}

/**
 * Best display string for a sender: brand senders pass through (uppercase),
 * VN phone numbers convert to local format, others pass through.
 */
export function formatSenderDisplay(sender: string | null | undefined): string {
  if (!sender) return "";
  const kind = classifySender(sender);
  if (kind === "brand") return sender.trim().toUpperCase();
  if (kind === "phone") return formatPhoneDisplay(sender);
  return sender.trim();
}
