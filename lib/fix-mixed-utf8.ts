// =============================================================================
// fix-mixed-utf8 — Repair byte streams that mix UTF-8 multi-byte sequences
// with stray Latin-1/CP-1252 single bytes
// =============================================================================
//
// Why this exists
// ---------------
// `sms_tool recv -j` on the Quectel RM520N modem decodes UCS-2 PDU payloads
// into UTF-8 for most code points but, for some characters in the U+0080–
// U+00FF range (e.g. à U+00E0, ò U+00F2, À U+00C0), it writes the code point
// as a SINGLE Latin-1 byte (0xE0, 0xF2, 0xC0) instead of the correct 2-byte
// UTF-8 sequence (C3 A0, C3 B2, C3 80). The resulting stream is INVALID
// UTF-8 — the browser's JSON / Response decoder replaces those bytes with
// the Unicode replacement character � (U+FFFD), showing in the SMS table as
// "V�o My VNPT" instead of "Vào My VNPT".
//
// What this does
// --------------
// Walk the byte stream. For each byte:
//   - If it's ASCII (< 0x80), keep as-is
//   - If it's the start of a valid UTF-8 multi-byte sequence (2/3/4 bytes)
//     AND the continuation bytes are present, keep the whole sequence
//   - Otherwise, treat the byte as Latin-1 and re-encode as 2-byte UTF-8
//     (Latin-1 0x80–0xBF → C2 + byte; 0xC0–0xFF → C3 + (byte − 0x40))
//
// This preserves correctly-encoded chunks while repairing the broken ones,
// unlike a blanket `iconv -f WINDOWS-1252` which would re-decode the good
// 3-byte sequences and mangle them.
// =============================================================================

/**
 * Repair a byte stream that mixes valid UTF-8 with stray Latin-1 bytes.
 * Returns the UTF-8-decoded JS string.
 */
export function fixMixedUtf8(bytes: Uint8Array): string {
  // Build a corrected byte buffer first, then run it through TextDecoder
  // in strict mode — anything still invalid after the walk is genuine
  // corruption and falls back to U+FFFD.
  const out: number[] = [];
  const n = bytes.length;
  let i = 0;

  while (i < n) {
    const b = bytes[i];

    // ASCII fast path
    if (b < 0x80) {
      out.push(b);
      i += 1;
      continue;
    }

    // Try to match a valid UTF-8 multi-byte sequence at position i.
    // 2-byte: 110xxxxx 10xxxxxx (b in 0xC2..0xDF)
    if (b >= 0xc2 && b <= 0xdf && i + 1 < n && isCont(bytes[i + 1])) {
      out.push(b, bytes[i + 1]);
      i += 2;
      continue;
    }
    // 3-byte: 1110xxxx 10xxxxxx 10xxxxxx (b in 0xE0..0xEF)
    if (
      b >= 0xe0 &&
      b <= 0xef &&
      i + 2 < n &&
      isCont(bytes[i + 1]) &&
      isCont(bytes[i + 2])
    ) {
      out.push(b, bytes[i + 1], bytes[i + 2]);
      i += 3;
      continue;
    }
    // 4-byte: 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx (b in 0xF0..0xF4)
    if (
      b >= 0xf0 &&
      b <= 0xf4 &&
      i + 3 < n &&
      isCont(bytes[i + 1]) &&
      isCont(bytes[i + 2]) &&
      isCont(bytes[i + 3])
    ) {
      out.push(b, bytes[i + 1], bytes[i + 2], bytes[i + 3]);
      i += 4;
      continue;
    }

    // Stray high byte — treat as Latin-1 and re-encode to 2-byte UTF-8
    if (b < 0xc0) {
      // 0x80..0xBF → U+0080..U+00BF → C2 + b
      out.push(0xc2, b);
    } else {
      // 0xC0..0xFF → U+00C0..U+00FF → C3 + (b - 0x40)
      out.push(0xc3, b - 0x40);
    }
    i += 1;
  }

  return new TextDecoder("utf-8", { fatal: false }).decode(new Uint8Array(out));
}

function isCont(b: number): boolean {
  return (b & 0xc0) === 0x80;
}

/**
 * Fetch and parse a JSON response while repairing mixed UTF-8 in the body.
 * Use this in place of `await resp.json()` when the upstream may emit stray
 * Latin-1 bytes (currently: SMS endpoint).
 */
export async function fetchJsonFixed<T>(resp: Response): Promise<T> {
  const buf = await resp.arrayBuffer();
  const text = fixMixedUtf8(new Uint8Array(buf));
  return JSON.parse(text) as T;
}
