"use client";

import { ActivityIcon, WifiIcon, WifiOffIcon } from "lucide-react";

import { Card } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import { getLatencyQuality, type ConnectivityStatus } from "@/types/modem-status";
import { cn } from "@/lib/utils";

interface InternetQualityWidgetProps {
  connectivity: ConnectivityStatus | null;
  isLoading?: boolean;
  className?: string;
}

// =============================================================================
// InternetQualityWidget — Connection tier + avg latency (QManager-VN)
// =============================================================================
// Replaces the "Connected / Disconnected" badge from Simple Admin with a more
// actionable summary: tier label (Excellent / Good / Fair / Poor) derived from
// the 30-minute average latency, plus the actual ms reading underneath.
//
// Uses `getLatencyQuality` from types/modem-status.ts so the thresholds stay
// in sync with the rest of the app (no separate magic numbers here).
//
// Special states:
//   - Loading (no connectivity yet) → skeleton
//   - internet_available === false → "Offline" + WifiOff icon (destructive)
//   - latency_history empty → "No data" (muted)
// =============================================================================

type Tier = "excellent" | "good" | "fair" | "poor" | "none" | "offline";

const TIER_LABEL: Record<Tier, string> = {
  excellent: "Excellent",
  good: "Good",
  fair: "Fair",
  poor: "Poor",
  none: "No data",
  offline: "Offline",
};

const TIER_CLASSES: Record<Tier, string> = {
  excellent: "text-success",
  good: "text-success",
  fair: "text-warning",
  poor: "text-destructive",
  none: "text-muted-foreground",
  offline: "text-destructive",
};

function computeAverage(history: (number | null)[] | undefined): number | null {
  if (!history || history.length === 0) return null;
  const valid = history.filter((v): v is number => typeof v === "number");
  if (valid.length === 0) return null;
  return valid.reduce((sum, v) => sum + v, 0) / valid.length;
}

export function InternetQualityWidget({
  connectivity,
  isLoading,
  className,
}: InternetQualityWidgetProps) {
  if (isLoading && !connectivity) {
    return (
      <Card className={cn("p-6 flex flex-col items-center justify-center min-h-[200px] h-full", className)}>
        <Skeleton className="size-12 rounded-full mb-3" />
        <Skeleton className="h-10 w-24 mb-2" />
        <Skeleton className="h-4 w-20" />
      </Card>
    );
  }

  const internetDown = connectivity?.internet_available === false;
  const avgLatency = computeAverage(connectivity?.latency_history);
  const tier: Tier = internetDown
    ? "offline"
    : (getLatencyQuality(avgLatency) as Tier);

  const Icon = internetDown ? WifiOffIcon : tier === "none" ? WifiIcon : ActivityIcon;
  const tierClass = TIER_CLASSES[tier];

  const subText =
    tier === "offline"
      ? "No internet"
      : tier === "none"
      ? "Awaiting samples"
      : `avg ${Math.round(avgLatency!)} ms`;

  // Tooltip detail uses the full connectivity object so the user can see
  // jitter / packet loss / sample size without leaving the dashboard.
  const sampleCount =
    connectivity?.latency_history?.filter((v) => typeof v === "number").length ?? 0;
  const tooltipText = internetDown
    ? "Internet unreachable — check antenna / SIM data plan."
    : tier === "none"
    ? "Ping daemon hasn't collected enough samples yet."
    : `Avg ${Math.round(avgLatency!)} ms · ` +
      `loss ${connectivity?.packet_loss_pct?.toFixed(1) ?? "0.0"}% · ` +
      `${sampleCount} samples in last 30m`;

  return (
    <Tooltip>
      <TooltipTrigger asChild>
        <Card
          className={cn(
            "p-6 flex flex-col items-center justify-center text-center min-h-[200px] h-full",
            className,
          )}
        >
          <Icon className={cn("size-12 mb-3", tierClass)} />
          <div className={cn("text-4xl font-bold", tierClass)}>
            {TIER_LABEL[tier]}
          </div>
          <div className="text-sm font-semibold uppercase tracking-wide text-muted-foreground mt-2">
            {subText}
          </div>
        </Card>
      </TooltipTrigger>
      <TooltipContent className="max-w-xs">{tooltipText}</TooltipContent>
    </Tooltip>
  );
}
