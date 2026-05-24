/**
 * Feature gating — gate UI features by detected modem capabilities.
 *
 * QManager-VN supports the SDXLEMUR family but some features only work on
 * specific firmware/model combinations (e.g. MBN profile select requires
 * pre-shipped MBN files; antenna alignment needs 4x4 MIMO ports).
 *
 * Pages that gate themselves call `isFeatureAvailable(hardware, feature)` and
 * show a "not available on this model" tooltip instead of throwing 500s on
 * unsupported AT commands.
 */

import type { HardwareInfo, SupportTier } from "@/types/hardware-info";

export type GatedFeature =
  | "mbn_profiles"
  | "antenna_alignment"
  | "antenna_statistics"
  | "tower_lock"
  | "nr5g_sa"
  | "speedtest";

/**
 * Returns true if a feature is expected to work on the detected hardware.
 *
 * Conservative: when in doubt (unknown model, missing detection), return true
 * and let the underlying AT command fail with a user-friendly error. The point
 * here is to PRE-empt obvious mismatches, not to be a strict gate.
 */
export function isFeatureAvailable(
  hardware: HardwareInfo | null,
  feature: GatedFeature,
): boolean {
  // No info yet → optimistic
  if (!hardware || hardware.model === "unknown") return true;

  switch (feature) {
    case "mbn_profiles":
      // MBN profiles shipped on global SKUs (-GL, -GLAA, -EU). RM500Q-GL also
      // has them. The Q variants and unknowns may not.
      // Anchored on both ends so the alternation matches the whole model
      // string — avoids a future edit accidentally dropping the leading `^`
      // on the second branch.
      return /^(RM52(0N|1F)-G[LU]|RM500Q-GL)/.test(hardware.model);

    case "antenna_alignment":
    case "antenna_statistics":
      // RM520N/521F have 4 antenna ports; RM502Q and RM500Q have 4 as well in
      // the SDXLEMUR family. Treat all SDXLEMUR as supported.
      return hardware.soc.startsWith("SDX62");

    case "tower_lock":
    case "nr5g_sa":
      // 5G SA requires firmware support; the GLAA/GL versions in our matrix all
      // ship with SA enabled. RM500Q-GL was originally NSA-only on early firmware
      // — gate optimistically and let the AT command surface the error.
      return hardware.support_tier !== "unsupported";

    case "speedtest":
      // Pure user-space, no AT dependency — always available.
      return true;
  }
}

/**
 * Whether to show the "this model is not officially tested" banner.
 *
 * Returns true for best-effort and unsupported tiers. False for primary/tested,
 * or while detection is in progress (null hardware).
 */
export function shouldShowUnsupportedBanner(hardware: HardwareInfo | null): boolean {
  if (!hardware) return false;
  if (hardware.model === "unknown") return false; // Detection still pending
  const flagged: SupportTier[] = ["best-effort", "unsupported"];
  return flagged.includes(hardware.support_tier);
}
