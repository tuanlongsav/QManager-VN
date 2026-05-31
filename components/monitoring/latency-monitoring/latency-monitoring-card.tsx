"use client";

// =============================================================================
// LatencyMonitoringCard — the recharts-backed chart.
// =============================================================================
// This file owns the only recharts import in the app. It is loaded via
// next/dynamic from latency-monitoring.tsx so recharts ships in a lazy chunk
// that downloads only when the latency page is opened. The data hook lives in
// ./use-latency-monitoring so importing it never drags recharts in statically.

import { useState } from "react";
import { motion, AnimatePresence } from "motion/react";
import { BarChart, CartesianGrid, XAxis, Bar } from "recharts";
import type { ViewMode, ChartDataPoint } from "./use-latency-monitoring";

import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";

import {
  ChartConfig,
  ChartContainer,
  ChartTooltip,
  ChartTooltipContent,
} from "@/components/ui/chart";

import { Tabs, TabsList, TabsTrigger } from "@/components/ui/tabs";

// =============================================================================
// Chart Config
// =============================================================================

const chartConfig = {
  latency: {
    label: "Latency",
    color: "var(--chart-3)",
  },
  packet_loss: {
    label: "Packet Loss",
    color: "var(--chart-6)",
  },
} satisfies ChartConfig;

const VIEW_INFO: Record<ViewMode, string> = {
  realtime:
    "Real-time ping results from the last 50 seconds. Each bar represents a single ping.",
  hourly: "Hourly averages of latency and packet loss over the last 24 hours.",
  twelvehour: "12-hour period averages of latency and packet loss.",
  daily: "Daily averages of latency and packet loss.",
};

// =============================================================================
// Chart Card Component
// =============================================================================

interface LatencyMonitoringCardProps {
  viewMode: ViewMode;
  setViewMode: (mode: ViewMode) => void;
  chartData: ChartDataPoint[];
  total: { latency: number; packet_loss: number };
}

const LatencyMonitoringCard = ({
  viewMode,
  setViewMode,
  chartData,
  total,
}: LatencyMonitoringCardProps) => {
  const [activeChart, setActiveChart] = useState<"latency" | "packet_loss">(
    "latency",
  );

  return (
    <Card>
      <CardHeader className="flex flex-col items-stretch border-b p-0 sm:flex-row">
        <div className="flex flex-1 flex-col justify-center gap-1 px-6 pt-4 pb-3 sm:py-6">
          <CardTitle>Internet Quality Monitor</CardTitle>
          <CardDescription>{VIEW_INFO[viewMode]}</CardDescription>
        </div>
        <div className="flex">
          {(["latency", "packet_loss"] as const).map((key) => (
            <button
              key={key}
              type="button"
              aria-pressed={activeChart === key}
              aria-label={`Show ${chartConfig[key].label} chart`}
              data-active={activeChart === key}
              className="data-[active=true]:bg-muted/50 relative z-30 flex flex-1 flex-col justify-center gap-1 border-t px-6 py-4 text-left even:border-l sm:border-t-0 sm:border-l sm:px-8 sm:py-6"
              onClick={() => setActiveChart(key)}
            >
              <span className="text-muted-foreground text-xs">
                {chartConfig[key].label}
              </span>
              <AnimatePresence mode="wait" initial={false}>
                <motion.span
                  key={Math.round(total[key])}
                  initial={{ opacity: 0, y: -5 }}
                  animate={{ opacity: 1, y: 0 }}
                  exit={{ opacity: 0, y: 5 }}
                  transition={{ duration: 0.18, ease: "easeOut" }}
                  className="text-base leading-none font-bold sm:text-3xl tabular-nums"
                >
                  {total[key].toLocaleString()}
                  {key === "latency" ? "ms" : "%"}
                </motion.span>
              </AnimatePresence>
            </button>
          ))}
        </div>
      </CardHeader>
      <CardContent className="px-2 pt-4 sm:p-6">
        <Tabs
          defaultValue="realtime"
          onValueChange={(value) => setViewMode(value as ViewMode)}
        >
          <TabsList>
            <TabsTrigger value="realtime">Real Time</TabsTrigger>
            <TabsTrigger value="hourly">Hourly</TabsTrigger>
            <TabsTrigger value="twelvehour">12 Hours</TabsTrigger>
            <TabsTrigger value="daily">Daily</TabsTrigger>
          </TabsList>
        </Tabs>
        <ChartContainer
          config={chartConfig}
          className="aspect-auto h-[250px] w-full mt-4"
        >
          <BarChart
            accessibilityLayer
            data={chartData}
            margin={{ left: 12, right: 12 }}
          >
            <CartesianGrid vertical={false} />
            <XAxis
              dataKey="timestamp"
              tickLine={false}
              axisLine={false}
              tickMargin={8}
              minTickGap={16}
              tickFormatter={(value) => {
                const date = new Date(value);
                if (viewMode === "realtime") {
                  return date.toLocaleTimeString(undefined, {
                    hour: "2-digit",
                    minute: "2-digit",
                  });
                } else if (viewMode === "hourly" || viewMode === "twelvehour") {
                  return date.toLocaleTimeString(undefined, {
                    hour: "2-digit",
                  });
                } else {
                  return date.toLocaleDateString(undefined, {
                    month: "short",
                    day: "numeric",
                  });
                }
              }}
            />
            <ChartTooltip
              content={
                <ChartTooltipContent
                  className="min-w-[180px] w-auto"
                  labelFormatter={(_value, payload) => {
                    const ts = payload?.[0]?.payload?.timestamp;
                    if (!ts) return "";
                    if (viewMode === "daily") {
                      return new Date(ts).toLocaleDateString(undefined, {
                        month: "short",
                        day: "numeric",
                        year: "numeric",
                      });
                    }
                    return new Date(ts).toLocaleString(undefined, {
                      month: "short",
                      day: "numeric",
                      hour: "2-digit",
                      minute: "2-digit",
                    });
                  }}
                />
              }
            />
            <Bar
              dataKey={activeChart}
              fill={`var(--color-${activeChart})`}
              radius={[4, 4, 0, 0]}
            />
          </BarChart>
        </ChartContainer>
      </CardContent>
    </Card>
  );
};

export default LatencyMonitoringCard;
