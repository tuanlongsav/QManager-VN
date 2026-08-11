"use client";

// =============================================================================
// useLatencyMonitoring — data hook, deliberately free of recharts/motion.
// =============================================================================
// This module is imported STATICALLY by latency-monitoring.tsx, while the chart
// component (which pulls in recharts) is loaded with next/dynamic. Keeping the
// hook here — separate from the recharts-importing card — is what lets the
// bundler push recharts into a lazy chunk that only downloads when the user
// actually opens the latency page.

import { useState, useMemo } from "react";
import { useModemStatus } from "@/hooks/use-modem-status";
import { useLatencyHistory } from "@/hooks/use-latency-history";
import type { PingHistoryEntry } from "@/types/modem-status";
import type { PingEntry } from "./ping-entries-card";

// =============================================================================
// Types
// =============================================================================

export type ViewMode = "realtime" | "hourly" | "twelvehour" | "daily";

interface RealtimeDataPoint {
  timestamp: number;
  latency: number;
  packet_loss: number;
  ok: boolean;
}

interface AggregatedDataPoint {
  timestamp: number;
  latency: number;
  packet_loss: number;
  sampleCount: number;
}

export interface ChartDataPoint {
  timestamp: number;
  latency: number;
  packet_loss: number;
}

const EMPTY_MESSAGES: Record<ViewMode, string> = {
  realtime: "No real-time data available.",
  hourly: "No hourly data available.",
  twelvehour: "No 12-hour data available.",
  daily: "No daily data available.",
};

/** Max entries shown in the chart and table for real-time view */
const REALTIME_LIMIT = 10;

// =============================================================================
// Helper Functions
// =============================================================================

function buildRealtimeData(
  history: (number | null)[],
  intervalSec: number,
  historySize: number,
): RealtimeDataPoint[] {
  const now = Date.now();
  return history.map((value, i) => {
    const timestamp = now - (historySize - i - 1) * intervalSec * 1000;
    if (value === null) {
      return { timestamp, latency: 0, packet_loss: 100, ok: false };
    }
    return { timestamp, latency: value, packet_loss: 0, ok: true };
  });
}

function aggregateByBucket(
  entries: PingHistoryEntry[],
  bucketMs: number,
): AggregatedDataPoint[] {
  if (entries.length === 0) return [];

  const buckets = new Map<
    number,
    { sumLat: number; countLat: number; countNull: number; total: number }
  >();

  for (const entry of entries) {
    const ts = entry.ts * 1000;
    const bucketStart = Math.floor(ts / bucketMs) * bucketMs;

    let bucket = buckets.get(bucketStart);
    if (!bucket) {
      bucket = { sumLat: 0, countLat: 0, countNull: 0, total: 0 };
      buckets.set(bucketStart, bucket);
    }

    bucket.total++;
    if (entry.lat === null) {
      bucket.countNull++;
    } else {
      bucket.sumLat += entry.lat;
      bucket.countLat++;
    }
  }

  const result: AggregatedDataPoint[] = [];
  for (const [timestamp, bucket] of buckets) {
    result.push({
      timestamp,
      latency:
        bucket.countLat > 0
          ? Math.round((bucket.sumLat / bucket.countLat) * 10) / 10
          : 0,
      packet_loss:
        bucket.total > 0
          ? Math.round((bucket.countNull / bucket.total) * 100 * 10) / 10
          : 0,
      sampleCount: bucket.total,
    });
  }

  result.sort((a, b) => a.timestamp - b.timestamp);
  return result;
}

function computeTotals(data: ChartDataPoint[]): {
  latency: number;
  packet_loss: number;
} {
  if (data.length === 0) return { latency: 0, packet_loss: 0 };

  const sumLat = data.reduce((acc, d) => acc + d.latency, 0);
  const sumLoss = data.reduce((acc, d) => acc + d.packet_loss, 0);

  return {
    latency: Math.round((sumLat / data.length) * 10) / 10,
    packet_loss: Math.round((sumLoss / data.length) * 10) / 10,
  };
}

// =============================================================================
// Hook: useLatencyMonitoring
// =============================================================================
// Exposes table entries + metadata so the parent can pass them to PingEntriesCard.

export interface LatencyMonitoringData {
  entries: PingEntry[];
  emptyMessage: string;
  isRealtime: boolean;
}

export function useLatencyMonitoring() {
  const [viewMode, setViewMode] = useState<ViewMode>("realtime");

  const { data: modemStatus } = useModemStatus({ pollInterval: 5000 });
  const { data: pingHistory } = useLatencyHistory({
    enabled: viewMode !== "realtime",
  });

  const realtimeData = useMemo<RealtimeDataPoint[]>(() => {
    if (!modemStatus?.connectivity) return [];
    const { latency_history, history_interval_sec, history_size } =
      modemStatus.connectivity;
    if (!latency_history || latency_history.length === 0) return [];
    return buildRealtimeData(
      latency_history,
      history_interval_sec,
      history_size,
    );
  }, [modemStatus?.connectivity]);

  const hourlyData = useMemo(
    () => aggregateByBucket(pingHistory, 3_600_000),
    [pingHistory],
  );
  const twelveHourData = useMemo(
    () => aggregateByBucket(pingHistory, 43_200_000),
    [pingHistory],
  );
  const dailyData = useMemo(
    () => aggregateByBucket(pingHistory, 86_400_000),
    [pingHistory],
  );

  const chartData = useMemo<ChartDataPoint[]>(() => {
    switch (viewMode) {
      case "realtime":
        return realtimeData.slice(-REALTIME_LIMIT).map((d) => ({
          timestamp: d.timestamp,
          latency: d.latency,
          packet_loss: d.packet_loss,
        }));
      case "hourly":
        return hourlyData;
      case "twelvehour":
        return twelveHourData;
      case "daily":
        return dailyData;
      default:
        return [];
    }
  }, [viewMode, realtimeData, hourlyData, twelveHourData, dailyData]);

  const total = useMemo(() => {
    if (viewMode === "realtime" && modemStatus?.connectivity) {
      return {
        latency: modemStatus.connectivity.avg_latency_ms ?? 0,
        packet_loss: modemStatus.connectivity.packet_loss_pct,
      };
    }
    return computeTotals(chartData);
    // Depend on `modemStatus`, not `modemStatus?.connectivity`: React Compiler
    // infers the whole object here, and a narrower manual dep makes it bail out
    // of optimizing this hook entirely. The poller hands back a fresh object
    // each cycle anyway, so both spellings recompute at the same rate.
  }, [viewMode, modemStatus, chartData]);

  // Build table entries with uniform PingEntry shape
  const tableData = useMemo<LatencyMonitoringData>(() => {
    const isRealtime = viewMode === "realtime";

    let entries: PingEntry[];
    if (isRealtime) {
      // Take the most recent N entries
      entries = realtimeData.slice(-REALTIME_LIMIT);
    } else {
      const source =
        viewMode === "hourly"
          ? hourlyData
          : viewMode === "twelvehour"
            ? twelveHourData
            : dailyData;
      entries = source.map((d) => ({
        timestamp: d.timestamp,
        latency: d.latency,
        packet_loss: d.packet_loss,
        ok: true,
      }));
    }

    return {
      entries,
      emptyMessage: EMPTY_MESSAGES[viewMode],
      isRealtime,
    };
  }, [viewMode, realtimeData, hourlyData, twelveHourData, dailyData]);

  return { viewMode, setViewMode, chartData, total, tableData };
}
