"use client";

import { ActivityIcon, WifiIcon, WifiOffIcon } from "lucide-react";

import { Card } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import {
  getLatencyQuality,
  LATENCY_THRESHOLDS,
  type ConnectivityStatus,
} from "@/types/modem-status";
import { useT } from "@/hooks/use-i18n";
import { cn } from "@/lib/utils";

interface InternetQualityWidgetProps {
  connectivity: ConnectivityStatus | null;
  isLoading?: boolean;
  className?: string;
}

// =============================================================================
// InternetQualityWidget — Connection tier + avg latency (QManager-VN)
// =============================================================================
// Top-row companion to Temperature / SMS / DeviceInfo widgets. Shows:
//   - Big RAT-style tier label (Excellent / Good / Fair / Poor) with a
//     latency-derived quality score % beside it
//   - Avg latency in ms underneath
//
// `latencyToScore` maps the avg latency onto the same tier thresholds defined
// in modem-status.ts so the displayed % visually tracks the tier:
//   excellent (≤30ms) → 100%-90%
//   good (30→60ms)    → 90%-75%
//   fair (60→100ms)   → 75%-50%
//   poor (>100ms)     → 50%-0% (clamps at ~300ms)
// =============================================================================

type Tier = "excellent" | "good" | "fair" | "poor" | "none" | "offline";

const TIER_I18N_KEY: Record<Tier, string> = {
  excellent: "dashboard.qualityExcellent",
  good: "dashboard.qualityGood",
  fair: "dashboard.qualityFair",
  poor: "dashboard.qualityPoor",
  none: "dashboard.qualityNoData",
  offline: "dashboard.qualityOffline",
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

function latencyToScore(latencyMs: number | null): number | null {
  if (latencyMs === null || latencyMs === undefined) return null;
  const { excellent, good, fair } = LATENCY_THRESHOLDS;
  if (latencyMs <= 0) return 100;
  if (latencyMs <= excellent) {
    return Math.round(100 - (latencyMs / excellent) * 10);
  }
  if (latencyMs <= good) {
    return Math.round(90 - ((latencyMs - excellent) / (good - excellent)) * 15);
  }
  if (latencyMs <= fair) {
    return Math.round(75 - ((latencyMs - good) / (fair - good)) * 25);
  }
  // poor tier: clamp from fair threshold to 300ms latency = 0%
  const overshoot = Math.min(latencyMs - fair, 200);
  return Math.max(0, Math.round(50 - (overshoot / 200) * 50));
}

export function InternetQualityWidget({
  connectivity,
  isLoading,
  className,
}: InternetQualityWidgetProps) {
  const { t } = useT();
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
  const score = tier === "offline" || tier === "none" ? null : latencyToScore(avgLatency);

  const Icon = internetDown ? WifiOffIcon : tier === "none" ? WifiIcon : ActivityIcon;
  const tierClass = TIER_CLASSES[tier];

  const subText =
    tier === "offline"
      ? t("dashboard.noInternet")
      : tier === "none"
      ? t("dashboard.awaitingSamples")
      : t("dashboard.avgLatency", { value: Math.round(avgLatency!) });

  // Tooltip detail uses the full connectivity object so the user can see
  // jitter / packet loss / sample size without leaving the dashboard.
  const sampleCount =
    connectivity?.latency_history?.filter((v) => typeof v === "number").length ?? 0;
  const tooltipText = internetDown
    ? t("dashboard.internetUnreachableTooltip")
    : tier === "none"
    ? t("dashboard.awaitingSamplesTooltip")
    : `${t("dashboard.qualityScoreTooltip", { score: score ?? 0 })} · ` +
      `${t("dashboard.avgLatency", { value: Math.round(avgLatency!) })} · ` +
      `loss ${connectivity?.packet_loss_pct?.toFixed(1) ?? "0.0"}% · ` +
      `${sampleCount} samples`;

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
          <div className="flex items-baseline justify-center gap-2 flex-wrap">
            {score !== null && (
              <span className={cn("text-2xl font-bold tabular-nums", tierClass)}>
                {score}%
              </span>
            )}
            <div className={cn("text-4xl font-bold", tierClass)}>
              {t(TIER_I18N_KEY[tier])}
            </div>
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
