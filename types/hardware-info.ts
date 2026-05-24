/**
 * Hardware info returned by /cgi-bin/quecmanager/system/hardware-info.sh.
 *
 * Written by detect_hardware.sh during poller boot — once per device per boot
 * (skipped if /etc/qmanager/hardware.json already exists).
 *
 * Used by UI for: model badge, dynamic band whitelist, feature gating,
 * "unsupported model" banner.
 */
export interface HardwareInfo {
  /** Modem model from AT+CGMM, normalized (e.g. "RM520N-GLAA"). "unknown" if AT probe failed. */
  model: string;
  /** Firmware version from AT+CGMR (e.g. "RM520NGLAAR01A08M4G_01.206.01.206"). */
  firmware: string;
  /** IMEI from AT+CGSN. */
  imei: string;
  /** SoC family inferred from model prefix (e.g. "SDX62 (SDXLEMUR)"). */
  soc: string;
  /** Support level for this model in the QManager-VN fork. */
  support_tier: SupportTier;
  /** AT command device path — always "/dev/smd11" for SDXLEMUR family. */
  at_device: string;
  /** ISO-8601 timestamp when this snapshot was written, or null if unavailable. */
  detected_at: string | null;
  /** Set when hardware.json could not be read or generated. */
  error?: string;
}

export type SupportTier = "primary" | "tested" | "best-effort" | "unsupported";

/** Human-readable label for each support tier (UI display). */
export const SUPPORT_TIER_LABEL: Record<SupportTier, string> = {
  primary: "Primary tested",
  tested: "Tested",
  "best-effort": "Best-effort",
  unsupported: "Unsupported",
};
