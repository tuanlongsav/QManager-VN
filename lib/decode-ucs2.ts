// =============================================================================
// decode-ucs2 — Decode UCS-2 hex strings to JS strings
// =============================================================================
//
// Why this exists
// ---------------
// On the RM520N modem, `sms_tool recv -j` has a buggy UCS-2 → UTF-8 decoder
// that replaces code points U+0080–U+00FF (Vietnamese precomposed Latin-1
// characters à/á/ò/ê/ý/...) with the Unicode replacement character U+FFFD.
// Code points outside that range (e.g. ặ U+1EB7, đ U+0111) survive intact.
//
// To recover lossless content, the backend now reads SMS storage with
// `AT+CMGF=1; AT+CSCS="UCS2"; AT+CMGL="ALL"` and supplies the raw UCS-2 hex
// per message as `content_hex`. This module decodes that hex to the proper
// JS string.
//
// Hex format: each UCS-2 code unit is 4 hex chars, big-endian. E.g.
// "005600E0006F" = U+0056 (V) + U+00E0 (à) + U+006F (o) = "Vào".
// =============================================================================

/**
 * Decode a UCS-2 hex string to a JS string. Returns "" for null/empty/invalid
 * input. Tolerates whitespace and mixed case in the hex input. Supplementary
 * plane characters (>U+FFFF) are returned as their surrogate pairs as-is
 * since UCS-2 doesn't encode them natively anyway.
 */
export function decodeUcs2Hex(hex: string | null | undefined): string {
  if (!hex) return "";
  const cleaned = hex.replace(/\s+/g, "");
  if (cleaned.length === 0 || cleaned.length % 4 !== 0) {
    // If length isn't a multiple of 4 the source is malformed; decode what
    // we can but don't throw — caller will fall back to broken content.
  }
  let result = "";
  const len = cleaned.length - (cleaned.length % 4);
  for (let i = 0; i < len; i += 4) {
    const codeUnit = parseInt(cleaned.substring(i, i + 4), 16);
    if (Number.isNaN(codeUnit)) continue;
    result += String.fromCharCode(codeUnit);
  }
  return result;
}
