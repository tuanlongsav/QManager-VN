/**
 * Per-model band whitelist for the SDXLEMUR (Qualcomm SDX62) family.
 *
 * Each entry lists the LTE, NR5G-SA, and NR5G-NSA bands documented in the
 * Quectel datasheet for that SKU. The UI band selector filters its options
 * against this whitelist for the currently detected model and warns when a
 * user picks a band outside the datasheet.
 *
 * Sources:
 * - RM520N-GL / GLAA: Quectel RM520N-GL Hardware Design v1.0 + product page
 *   https://www.quectel.com/product/5g-rm520n-series/
 * - RM502Q-AE / RM500Q-GL: Quectel x52 datasheet (SDXLEMUR family)
 * - RM520N-EU: EU variant of RM520N-GL with EU-only band subset
 *
 * Important: these lists describe what the radio CAN tune to in firmware.
 * Local regulatory bodies may forbid some bands in some regions; cross-check
 * with VN_BAND_WHITELIST in Phase D before allowing in Vietnam UIs.
 */

export interface BandWhitelist {
  /** LTE FDD + TDD band numbers (3GPP). */
  lte: number[];
  /** NR5G SA mode band numbers (3GPP, "n" prefix dropped). */
  nr_sa: number[];
  /** NR5G NSA mode band numbers (3GPP, "n" prefix dropped). */
  nr_nsa: number[];
}

/**
 * Models known to QManager-VN. The `_default` key is the fallback for any
 * model the fork hasn't characterized — uses the broadest known LTE/NR set so
 * the user can still operate, with a warning banner.
 */
export const BAND_WHITELIST: Record<string, BandWhitelist> = {
  // Primary tested (longht's hardware) — Global SKU, US/Asia bands
  "RM520N-GLAA": {
    lte: [1, 2, 3, 4, 5, 7, 8, 12, 13, 14, 17, 18, 19, 20, 25, 26, 28, 29, 30, 32, 34, 38, 39, 40, 41, 42, 43, 46, 48, 66, 71],
    nr_sa: [1, 2, 3, 5, 7, 8, 12, 20, 25, 28, 38, 40, 41, 48, 66, 71, 77, 78, 79],
    nr_nsa: [1, 2, 3, 5, 7, 8, 12, 20, 25, 28, 38, 40, 41, 48, 66, 71, 77, 78, 79],
  },
  // Tested-by-upstream — same datasheet as GLAA (GL is the base SKU)
  "RM520N-GL": {
    lte: [1, 2, 3, 4, 5, 7, 8, 12, 13, 14, 17, 18, 19, 20, 25, 26, 28, 29, 30, 32, 34, 38, 39, 40, 41, 42, 43, 46, 48, 66, 71],
    nr_sa: [1, 2, 3, 5, 7, 8, 12, 20, 25, 28, 38, 40, 41, 48, 66, 71, 77, 78, 79],
    nr_nsa: [1, 2, 3, 5, 7, 8, 12, 20, 25, 28, 38, 40, 41, 48, 66, 71, 77, 78, 79],
  },
  // Best-effort EU variant — EU bands only
  "RM520N-EU": {
    lte: [1, 3, 5, 7, 8, 20, 28, 32, 38, 40, 41, 42, 43],
    nr_sa: [1, 3, 7, 8, 20, 28, 38, 40, 41, 77, 78],
    nr_nsa: [1, 3, 7, 8, 20, 28, 38, 40, 41, 77, 78],
  },
  // Best-effort — RM502Q-AE (5G Sub-6 Stage 2, Asia/EU SKU)
  "RM502Q-AE": {
    lte: [1, 2, 3, 4, 5, 7, 8, 12, 13, 14, 17, 18, 19, 20, 25, 26, 28, 29, 30, 32, 34, 38, 39, 40, 41, 42, 43, 46, 48, 66, 71],
    nr_sa: [1, 2, 3, 5, 7, 8, 20, 28, 38, 40, 41, 48, 66, 77, 78, 79],
    nr_nsa: [1, 2, 3, 5, 7, 8, 20, 28, 38, 40, 41, 48, 66, 77, 78, 79],
  },
  // Best-effort — RM500Q-GL (5G Sub-6 Stage 1, global)
  "RM500Q-GL": {
    lte: [1, 2, 3, 4, 5, 7, 8, 12, 13, 17, 18, 19, 20, 25, 26, 28, 29, 30, 32, 34, 38, 39, 40, 41, 42, 43, 46, 48, 66, 71],
    nr_sa: [1, 2, 3, 5, 7, 8, 20, 28, 38, 40, 41, 66, 77, 78, 79],
    nr_nsa: [1, 2, 3, 5, 7, 8, 20, 28, 38, 40, 41, 66, 77, 78, 79],
  },
  _default: {
    lte: [1, 2, 3, 4, 5, 7, 8, 12, 17, 20, 25, 28, 38, 40, 41, 66, 71],
    nr_sa: [1, 2, 3, 5, 7, 8, 20, 28, 38, 40, 41, 66, 77, 78, 79],
    nr_nsa: [1, 2, 3, 5, 7, 8, 20, 28, 38, 40, 41, 66, 77, 78, 79],
  },
};

/**
 * Vietnam spectrum allocations as of 2026-05.
 * Use as a secondary filter on top of BAND_WHITELIST to warn when a band is
 * technically supported by the radio but not assigned for civilian use in VN.
 *
 * Sources:
 * - Cục Tần số (ARFM) public spectrum chart 2024
 * - Carrier coverage docs (Viettel/Vinaphone/Mobifone)
 */
export const VN_BAND_WHITELIST: BandWhitelist = {
  // LTE: B1 (2100), B3 (1800), B5 (850), B7 (2600), B8 (900), B20 (800),
  //      B28 (700), B38 (TDD 2600), B40 (TDD 2300), B41 (TDD 2500/2600)
  lte: [1, 3, 5, 7, 8, 20, 28, 38, 40, 41],
  // NR SA: n1, n3, n5, n28, n40, n41, n77, n78 (commercial deployments)
  nr_sa: [1, 3, 5, 28, 40, 41, 77, 78],
  nr_nsa: [1, 3, 5, 28, 40, 41, 77, 78],
};

/**
 * Look up the band whitelist for a model. Falls back to `_default` if the
 * model isn't characterized.
 */
export function getBandWhitelist(model: string | null | undefined): BandWhitelist {
  if (!model) return BAND_WHITELIST._default;
  return BAND_WHITELIST[model] ?? BAND_WHITELIST._default;
}
