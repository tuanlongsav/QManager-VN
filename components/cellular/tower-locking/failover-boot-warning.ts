import { toast } from "sonner";

// =============================================================================
// failover-boot-warning.ts — "saved, but not at boot" warning for tower cards
// =============================================================================
// Both tower endpoints (lock.sh and settings.sh) can succeed at the thing the
// user asked for while failing to write the signal-failover watcher's systemd
// boot symlink. The operation genuinely worked, so the success toast stays and
// this warning is added next to it — never toast.error, and never in place of
// the success.
//
// Shared by lte-locking, nr-sa-locking and tower-settings: all four lock/unlock
// paths plus all three settings controls hit endpoints that can report this,
// and the absent-means-unknown rule below is the kind of thing that only has to
// be got wrong in one of those seven places to be wrong everywhere.
// =============================================================================

/**
 * The optional half of TowerLockResponse / TowerSettingsResponse that reports
 * whether the failover watcher survives a reboot. Structural rather than a
 * union of the two response types, so it also accepts anything else that grows
 * the same pair of fields later.
 */
export interface FailoverBootAware {
  failover_boot_enabled?: boolean;
  failover_boot_error?: string;
}

/**
 * Warn when the failover watcher was NOT enabled at boot.
 *
 * Absent means UNKNOWN, not failure — a device on an older build never sends
 * the field, and warning on every save on every such device is how a warning
 * stops being read. Hence strict `=== false` rather than a falsy check: only an
 * explicit `false` from the backend warns.
 *
 * @param result   the parsed response body
 * @param fallback English shown when the server sent no error string
 */
export function warnIfFailoverBootFailed(
  result: FailoverBootAware,
  fallback: string,
): void {
  if (result.failover_boot_enabled === false) {
    toast.warning(result.failover_boot_error || fallback);
  }
}
