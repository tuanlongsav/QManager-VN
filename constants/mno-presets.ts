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
 * Suggest a preset based on the SIM's MCC/MNC. Returns the preset id or null
 * if no match. Used by the APN management UI to highlight the matching VN
 * carrier when a Vietnamese SIM is inserted (MCC 452).
 *
 * MNC values per GSMA Network Codes database and Wikipedia
 * (https://en.wikipedia.org/wiki/Mobile_country_code#Vietnam).
 */
export function suggestPresetFromImsi(imsi: string | null | undefined): string | null {
  if (!imsi || imsi.length < 5) return null;
  const mcc = imsi.substring(0, 3);
  const mnc = imsi.substring(3, 5);

  // Vietnam (MCC 452)
  if (mcc === "452") {
    // Viettel Telecom: 04 (main), 06 (legacy), 24 (data-only)
    if (mnc === "04" || mnc === "06" || mnc === "24") return "viettel";
    // Vinaphone (VNPT): 02 (main), 18 (legacy GSM)
    if (mnc === "02" || mnc === "18") return "vinaphone";
    // Mobifone (VMS): 01 (main), 03 (legacy), 07 (4G/5G)
    if (mnc === "01" || mnc === "03" || mnc === "07") return "mobifone";
    // Vietnamobile (Hutchison): 05 (formerly Beeline)
    if (mnc === "05") return "vietnamobile";
    // Wintel / Reddi / Mobicast: 09, 11 (MVNO over Viettel)
    if (mnc === "09" || mnc === "11") return "wintel";
    // Itelecom: 08 (MVNO over Vinaphone)
    if (mnc === "08") return "vinaphone";
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
