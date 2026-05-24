/**
 * Auto cell-lock state machine config + status (QManager-VN).
 *
 * Backend: scripts/usr/bin/qmanager_autolock (daemon)
 *          scripts/www/cgi-bin/quecmanager/cellular/autolock.sh (CGI)
 * Config:  /etc/qmanager/autolock.json
 * Status:  /tmp/qmanager_autolock_status.json
 */

export interface AutolockThresholds {
  /** RSRP threshold (dBm) above which signal is "stable". Default: -85. */
  rsrp_stable: number;
  /** SINR threshold (dB) above which signal is "stable". Default: 5. */
  sinr_stable: number;
  /** RSRP threshold (dBm) below which signal is "lost". Default: -110. */
  rsrp_lost: number;
  /** Consecutive samples required to transition state. Default: 3. */
  samples: number;
}

export interface AutolockConfig {
  enabled: boolean;
  thresholds: AutolockThresholds;
}

export type AutolockState = "idle" | "watching" | "locked" | "signal-lost";

export interface AutolockStatus {
  state: AutolockState;
  stable_count: number;
  lost_count: number;
  locked_pci: string | null;
  locked_earfcn: string | null;
  message: string;
  updated_at: string | null;
}

export interface AutolockResponse {
  success: boolean;
  config: AutolockConfig;
  status: AutolockStatus;
  service_active: boolean;
}

/** Display label for each state. */
export const AUTOLOCK_STATE_LABEL: Record<AutolockState, string> = {
  idle: "Idle",
  watching: "Watching",
  locked: "Locked",
  "signal-lost": "Signal lost",
};
