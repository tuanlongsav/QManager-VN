"use client";

import { GlobeIcon } from "lucide-react";
import {
  MdOutline5G,
  Md4gMobiledata,
  Md4gPlusMobiledata,
  Md3gMobiledata,
  MdEnergySavingsLeaf,
} from "react-icons/md";

import { Card } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import {
  formatUptime,
  type NetworkStatus,
  type ConnectivityStatus,
} from "@/types/modem-status";
import type { AboutDeviceData } from "@/types/about-device";
import { useT } from "@/hooks/use-i18n";
import { cn } from "@/lib/utils";

interface NetworkStatusCompactProps {
  network: NetworkStatus | null;
  device: { uptime_seconds: number } | null;
  aboutDevice: AboutDeviceData | null;
  connectivity: ConnectivityStatus | null;
  modemReachable: boolean;
  isLoading?: boolean;
  className?: string;
}

// =============================================================================
// NetworkStatusCompact — Square dashboard widget (QManager-VN)
// =============================================================================
// Top-row companion to Temperature / SMS / InternetQuality widgets. Adopts the
// Simple Admin "Connected VINAPHONE" visual but adds more at-a-glance info:
//   - Big RAT icon (5G / LTE+ / LTE / 3G) as the focal element
//   - Carrier name + RAT label
//   - Public IPv4 (truncated if too long)
//   - Uptime (modem boot-up duration)
//
// The pulse/ring animations from the original NetworkStatusComponent are
// dropped here for visual symmetry with the other 3 widgets. The user still
// gets full per-band detail in the LTE/NR/SCC cards below.
// =============================================================================

function pickRatIcon(type: string, caActive: boolean, isAirplane: boolean) {
  if (isAirplane) {
    return <MdEnergySavingsLeaf className="size-full text-success" />;
  }
  switch (type) {
    case "5G-SA":
    case "5G-NSA":
      return <MdOutline5G className="size-full text-white" />;
    case "LTE":
      return caActive ? (
        <Md4gPlusMobiledata className="size-full text-white" />
      ) : (
        <Md4gMobiledata className="size-full text-white" />
      );
    default:
      return <Md3gMobiledata className="size-full text-white/60" />;
  }
}

function ratLabelKey(type: string, caActive: boolean, isAirplane: boolean): string {
  if (isAirplane) return "dashboard.ratLowPower";
  switch (type) {
    case "5G-SA":
      return "dashboard.ratStandalone";
    case "5G-NSA":
      return "dashboard.ratNsa";
    case "LTE":
      return caActive ? "dashboard.ratLtePlus" : "dashboard.ratLte";
    default:
      return "dashboard.ratNoSignal";
  }
}

export function NetworkStatusCompact({
  network,
  device,
  aboutDevice,
  connectivity,
  modemReachable,
  isLoading,
  className,
}: NetworkStatusCompactProps) {
  const { t } = useT();
  const isAirplane = network?.cfun === 0 || network?.cfun === 4;
  const radioOn = modemReachable && !isAirplane;
  const hasNetwork =
    network?.type === "LTE" ||
    network?.type === "5G-SA" ||
    network?.type === "5G-NSA";

  if (isLoading && !network) {
    return (
      <Card className={cn("p-6 flex flex-col items-center justify-center min-h-[200px] h-full", className)}>
        <Skeleton className="size-12 rounded-full mb-3" />
        <Skeleton className="h-10 w-24 mb-2" />
        <Skeleton className="h-4 w-20" />
      </Card>
    );
  }

  const carrier = network?.carrier?.trim() || "—";
  const rat = network?.type ?? "";
  const caActive = network?.ca_active ?? false;
  const publicIp = aboutDevice?.network?.public_ipv4 ?? "—";
  const uptime = device?.uptime_seconds ? formatUptime(device.uptime_seconds) : "—";
  // Connectivity dot — small status indicator in the corner since we removed
  // the big pulse ring. Avoids confusion when a user is offline despite a
  // healthy RAT icon.
  const dotClass = !radioOn
    ? "bg-destructive"
    : connectivity?.internet_available === false
    ? "bg-destructive"
    : connectivity?.state === "limited"
    ? "bg-warning"
    : hasNetwork
    ? "bg-success"
    : "bg-muted-foreground";

  return (
    <Card
      className={cn(
        "p-6 flex flex-col items-center justify-center text-center min-h-[200px] h-full relative",
        className,
      )}
    >
      {/* Connectivity dot — top-right corner */}
      <span
        aria-hidden
        className={cn(
          "absolute top-3 right-3 inline-flex size-2.5 rounded-full",
          dotClass,
        )}
      />

      {/* Big RAT icon (same size as other widgets' icon) */}
      <div
        className={cn(
          "rounded-full size-12 flex items-center justify-center p-1 mb-3",
          isAirplane
            ? "bg-success/15"
            : hasNetwork
            ? "bg-primary"
            : "bg-muted",
        )}
      >
        {pickRatIcon(rat, caActive, isAirplane)}
      </div>

      {/* Carrier — primary text matching other widgets' 4xl bold pattern but
          allowing long carrier names to truncate gracefully */}
      <div className="text-2xl font-bold leading-tight truncate max-w-full">
        {carrier}
      </div>
      <div className="text-sm font-semibold uppercase tracking-wide text-muted-foreground mt-2">
        {t(ratLabelKey(rat, caActive, isAirplane))}
      </div>

      {/* Public IP + Uptime — same size as other widgets' "Temperature" /
          "avg N ms" subtitle so the 4 widgets feel uniform. */}
      <div className="text-sm font-semibold text-muted-foreground space-y-1 mt-3">
        <div className="flex items-center justify-center gap-1.5">
          <GlobeIcon className="size-4" />
          <span className="font-mono">{publicIp}</span>
        </div>
        <div>{t("dashboard.uptimePrefix")} {uptime}</div>
      </div>
    </Card>
  );
}
