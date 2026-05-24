"use client";

import { SignalIcon, RadioIcon } from "lucide-react";

import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import {
  getSignalQuality,
  RSRP_THRESHOLDS,
  RSRQ_THRESHOLDS,
  SINR_THRESHOLDS,
  type LteStatus,
  type NrStatus,
} from "@/types/modem-status";
import { cn } from "@/lib/utils";

type Quality = "excellent" | "good" | "fair" | "poor" | "none";

const QUALITY_LABEL: Record<Quality, string> = {
  excellent: "Excellent",
  good: "Good",
  fair: "Fair",
  poor: "Poor",
  none: "—",
};

const QUALITY_TEXT_CLASS: Record<Quality, string> = {
  excellent: "text-success",
  good: "text-success",
  fair: "text-warning",
  poor: "text-destructive",
  none: "text-muted-foreground",
};

const QUALITY_BG_CLASS: Record<Quality, string> = {
  excellent: "bg-success",
  good: "bg-success",
  fair: "bg-warning",
  poor: "bg-destructive",
  none: "bg-muted",
};

interface SignalQualityMonitorProps {
  lte: LteStatus | null;
  nr: NrStatus | null;
  isLoading?: boolean;
  className?: string;
}

// =============================================================================
// SignalQualityMonitor — Per-metric quality tiers at-a-glance (QManager-VN F.2)
// =============================================================================
// Replaces the deleted "Live Latency and Speed Test" widget with a more useful
// snapshot — what the user actually wants to know is whether the signal is
// good or bad, not how many ms a ping took.
//
// Shows three metrics for the currently active RAT (NR > LTE), each with:
//   - Raw value (dBm / dB)
//   - Quality tier (Excellent / Good / Fair / Poor)
//   - Color-tiered bar that fills proportional to the threshold band
//
// Thresholds come from RSRP_THRESHOLDS / RSRQ_THRESHOLDS / SINR_THRESHOLDS in
// types/modem-status.ts — same source the LTE/NR detail cards already use, so
// the numbers stay consistent across the dashboard.
// =============================================================================

interface MetricRowProps {
  label: string;
  value: number | null;
  unit: string;
  thresholds: typeof RSRP_THRESHOLDS;
  isLoading?: boolean;
}

function qualityFillPercent(value: number | null, thresholds: typeof RSRP_THRESHOLDS): number {
  if (value === null || value === undefined) return 0;
  // Map value linearly from "poor" floor to "excellent" ceiling. Beyond the
  // top of the band the bar pegs at 100%; below the bottom it shows 5% so
  // there's still a visible tick.
  const span = thresholds.excellent - thresholds.poor;
  if (span <= 0) return 50;
  const clamped = Math.max(0, Math.min(1, (value - thresholds.poor) / span));
  return Math.max(5, Math.round(clamped * 100));
}

function MetricRow({ label, value, unit, thresholds, isLoading }: MetricRowProps) {
  const quality = getSignalQuality(value, thresholds) as Quality;
  const fill = qualityFillPercent(value, thresholds);

  return (
    <div className="space-y-1.5">
      <div className="flex items-baseline justify-between gap-2">
        <span className="text-sm font-semibold text-muted-foreground uppercase tracking-wide">
          {label}
        </span>
        {isLoading ? (
          <Skeleton className="h-4 w-16" />
        ) : (
          <span
            className={cn(
              "text-xs font-semibold uppercase tracking-wide",
              QUALITY_TEXT_CLASS[quality],
            )}
          >
            {QUALITY_LABEL[quality]}
          </span>
        )}
      </div>
      <div className="flex items-center gap-3">
        <div className="flex-1 h-2 rounded-full bg-muted overflow-hidden">
          {!isLoading && value !== null && (
            <div
              className={cn("h-full rounded-full transition-all", QUALITY_BG_CLASS[quality])}
              style={{ width: `${fill}%` }}
            />
          )}
        </div>
        {isLoading ? (
          <Skeleton className="h-4 w-14" />
        ) : (
          <span className={cn("text-sm font-bold tabular-nums min-w-14 text-right", QUALITY_TEXT_CLASS[quality])}>
            {value !== null ? `${value} ${unit}` : "—"}
          </span>
        )}
      </div>
    </div>
  );
}

export function SignalQualityMonitor({ lte, nr, isLoading, className }: SignalQualityMonitorProps) {
  // Prefer NR if connected, else LTE. The user wants to see quality for the
  // RAT that's actually carrying their traffic.
  const nrConnected = nr?.state === "connected" || nr?.state === "limited";
  const showNr = nrConnected;
  const ratLabel = showNr ? "5G NR" : "LTE 4G";
  const Icon = showNr ? RadioIcon : SignalIcon;

  const rsrp = showNr ? nr?.rsrp ?? null : lte?.rsrp ?? null;
  const rsrq = showNr ? nr?.rsrq ?? null : lte?.rsrq ?? null;
  const sinr = showNr ? nr?.sinr ?? null : lte?.sinr ?? null;

  return (
    <Card className={cn("h-full", className)}>
      <CardHeader>
        <div className="flex items-center justify-between gap-2">
          <CardTitle className="text-lg">Signal Quality Monitor</CardTitle>
          <div className="inline-flex items-center gap-1.5 text-xs font-semibold uppercase tracking-wide text-muted-foreground">
            <Icon className="size-4" />
            {ratLabel}
          </div>
        </div>
        <CardDescription>
          Chất lượng tín hiệu hiện tại — RSRP / RSRQ / SINR theo band đang phục vụ.
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-4">
        <MetricRow label="RSRP" value={rsrp} unit="dBm" thresholds={RSRP_THRESHOLDS} isLoading={isLoading} />
        <MetricRow label="RSRQ" value={rsrq} unit="dB" thresholds={RSRQ_THRESHOLDS} isLoading={isLoading} />
        <MetricRow label="SINR" value={sinr} unit="dB" thresholds={SINR_THRESHOLDS} isLoading={isLoading} />
      </CardContent>
    </Card>
  );
}
