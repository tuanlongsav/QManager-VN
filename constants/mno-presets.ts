// =============================================================================
// mno-presets.ts — Mobile Network Operator Preset Configurations
// =============================================================================
// Shared carrier presets used by both Custom SIM Profiles and APN Management.
// Selecting a preset pre-fills APN, TTL, and HL fields.
// CID is NOT included — it is auto-detected via QMAP/CGPADDR cross-reference.
// Fields remain editable — the user can override any pre-filled value.
//
// To add a new carrier: append an entry to MNO_PRESETS below.
// The "Custom" option is always appended automatically by the form.
// =============================================================================

export interface MnoPreset {
  /** Unique key for this preset (used as Select value) */
  id: string;
  /** Display name in the dropdown */
  label: string;
  /** APN name to pre-fill */
  apn_name: string;
  /** IPv4 TTL value (0-255, 0 = don't change) */
  ttl: number;
  /** IPv6 Hop Limit value (0-255, 0 = don't change) */
  hl: number;
}

/**
 * Carrier preset list.
 * Add new carriers here — both Custom SIM Profiles and APN Management
 * dropdowns will automatically pick them up.
 */
export const MNO_PRESETS: MnoPreset[] = [
  // ─── Vietnam carriers (priority — QManager-VN audience) ────────────────
  {
    id: "viettel",
    label: "Viettel",
    apn_name: "v-internet",
    ttl: 64,
    hl: 64,
  },
  {
    id: "vinaphone",
    label: "Vinaphone",
    apn_name: "m3-world",
    ttl: 64,
    hl: 64,
  },
  {
    id: "mobifone",
    label: "Mobifone",
    apn_name: "m-i-internet",
    ttl: 64,
    hl: 64,
  },
  {
    id: "vietnamobile",
    label: "Vietnamobile",
    apn_name: "internet",
    ttl: 64,
    hl: 64,
  },
  {
    id: "wintel",
    label: "Wintel (Reddi / Mobicast)",
    apn_name: "v-internet",
    ttl: 64,
    hl: 64,
  },
  // ─── International (upstream presets) ──────────────────────────────────
  {
    id: "smart",
    label: "Smart (PH)",
    apn_name: "SMARTLTE",
    ttl: 64,
    hl: 64,
  },
  {
    id: "dito",
    label: "DITO (PH)",
    apn_name: "internet.dito.ph",
    ttl: 0,
    hl: 0,
  },
  {
    id: "gomo",
    label: "GOMO (PH)",
    apn_name: "gomo.ph",
    ttl: 0,
    hl: 0,
  },
  {
    id: "globe",
    label: "Globe (PH)",
    apn_name: "internet.globe.com.ph",
    ttl: 0,
    hl: 0,
  },
  {
    id: "vzw",
    label: "Verizon (US)",
    apn_name: "vzwinternet",
    ttl: 64,
    hl: 64,
  },
  {
    id: "att_5g_phone",
    label: "AT&T 5G Phone (US)",
    apn_name: "enhancedphone",
    ttl: 0,
    hl: 0,
  },
  {
    id: "tmo_home",
    label: "T-Mobile Home Internet (US)",
    apn_name: "fbb.home",
    ttl: 0,
    hl: 0,
  },
];

/**
 * Suggest a preset from the SIM's IMSI. Returns a preset id, or null when the
 * issuer is unknown or has no preset we can stand behind. Callers use it to
 * pre-fill the APN field on a profile that has none; returning null just means
 * the user types the APN themselves, which is the correct outcome whenever we
 * would otherwise be guessing.
 *
 * This keys on the IMSI, i.e. WHO ISSUED THE SIM. That is a different question
 * from the one `carrier_name_from_code()` in
 * scripts/usr/lib/qmanager/parse_at.sh answers, which keys on the registered
 * PLMN, i.e. WHOSE RADIO the modem is camped on. The two tables therefore
 * legitimately carry different rows: an MVNO has its own IMSI range but no
 * radio of its own, so it belongs here and not there. They must never
 * contradict each other on a fact, only on scope.
 *
 * Sourcing (all checked 2026-08-15). Vietnam's MNC assignments are taken from
 * the Wikipedia "Mobile network codes in ITU region 4xx (Asia)" table, Vietnam
 * section, corroborated row-for-row by https://mcc-mnc.org/countries/vietnam:
 * https://en.wikipedia.org/wiki/Mobile_network_codes_in_ITU_region_4xx_(Asia)
 *
 *   452-01 MobiFone      operational
 *   452-02 VinaPhone     operational
 *   452-03 S-Fone        licence revoked, MNC withdrawn
 *   452-04 Viettel       operational
 *   452-05 Vietnamobile  operational
 *   452-06 EVNTelecom    licence revoked, MNC withdrawn
 *   452-07 Gmobile       MVNO (moved from VinaPhone to MobiFone, June 2025)
 *   452-08 I-Telecom     MVNO on VinaPhone
 *   452-09 Wintel        MVNO on VinaPhone (formerly Reddi)
 *
 * Deliberately NOT mapped, so the APN field is left blank instead of seeded
 * with something wrong:
 *
 *   452-03, 452-06 — withdrawn. No SIM in circulation carries them, and a
 *   withdrawn MNC can be reassigned, so a mapping could only ever misfire.
 *   An earlier version of this file read them as MobiFone and Viettel legacy
 *   ranges; neither company ever held them.
 *
 *   452-07 Gmobile — no preset exists for it and its APN is not something we
 *   have verified. Its host network changed in 2025
 *   (https://www.mobifone.vn/tin-tuc/chi-tiet/thong-bao-chuyen-doi-thue-bao-gmobile-tren-ha-tang-mang-vinaphone-ve-mobifone-17961),
 *   which is also why seeding the host's APN would be a poor substitute.
 *
 *   452-08 I-Telecom — an MVNO's APN is served by its own core, so the host's
 *   APN is not a stand-in for it. iTel documents "m9-itelecom"
 *   (https://itel.vn/huong-dan-nguoi-dung/huong-dan-cai-dat-apn-iPhone), not
 *   VinaPhone's "m3-world", which is what this function used to seed.
 *
 *   452-11, 452-18, 452-24 — an earlier version of this file mapped these to
 *   Wintel, VinaPhone and Viettel. No source consulted lists any of them as
 *   assigned in MCC 452, so they are gone rather than kept on faith.
 */
export function suggestPresetFromImsi(imsi: string | null | undefined): string | null {
  if (!imsi || imsi.length < 5) return null;
  const mcc = imsi.substring(0, 3);
  const mnc = imsi.substring(3, 5);

  // Vietnam (MCC 452) only — no other MCC has presets worth guessing from.
  if (mcc === "452") {
    if (mnc === "01") return "mobifone";
    if (mnc === "02") return "vinaphone";
    if (mnc === "04") return "viettel";
    if (mnc === "05") return "vietnamobile";
    // Mobicast's own IMSI range, and Wintel is the preset for Mobicast — the
    // one MVNO here whose brand we carry, so the brand match is exact.
    if (mnc === "09") return "wintel";
  }
  return null;
}

/**
 * Special value for the "Custom" option in the MNO dropdown.
 * When selected, all pre-filled fields are cleared for manual entry.
 */
export const MNO_CUSTOM_ID = "custom";

/**
 * Look up a preset by ID. Returns undefined if not found or if "custom".
 */
export function getMnoPreset(id: string): MnoPreset | undefined {
  if (id === MNO_CUSTOM_ID) return undefined;
  return MNO_PRESETS.find((p) => p.id === id);
}
