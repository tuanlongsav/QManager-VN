"use client";

import { ThermometerIcon } from "lucide-react";

import { Card } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { cn } from "@/lib/utils";

interface TemperatureWidgetProps {
  /** Modem temperature in °C. null = sensor unavailable / not yet loaded. */
  temperature: number | null;
  isLoading?: boolean;
  className?: string;
}

// =============================================================================
// TemperatureWidget — Big-number °C card (QManager-VN)
// =============================================================================
// Compact dashboard widget styled after Simple Admin's top-row temperature
// tile. Reusable on:
// - Home top row (alongside Network / SMS / Internet Quality widgets)
// - About Device page (alongside device-information-card)
//
// Color tiers map to the standard QManager Status Badge pattern:
//   < 50 °C → success (cool)
//   50–65 °C → warning (warm — typical operating range under load)
//   > 65 °C → destructive (hot — modem may throttle)
// =============================================================================

function classifyTemp(t: number): "cool" | "warm" | "hot" {
  if (t < 50) return "cool";
  if (t <= 65) return "warm";
  return "hot";
}

const TIER_CLASSES: Record<"cool" | "warm" | "hot", { value: string; icon: string }> = {
  cool: { value: "text-success", icon: "text-success" },
  warm: { value: "text-warning", icon: "text-warning" },
  hot: { value: "text-destructive", icon: "text-destructive" },
};

export function TemperatureWidget({
  temperature,
  isLoading,
  className,
}: TemperatureWidgetProps) {
  if (isLoading && temperature === null) {
    return (
      <Card className={cn("p-6 flex flex-col items-center justify-center min-h-[180px]", className)}>
        <Skeleton className="size-12 rounded-full mb-3" />
        <Skeleton className="h-10 w-24 mb-2" />
        <Skeleton className="h-4 w-20" />
      </Card>
    );
  }

  const tier = temperature !== null ? classifyTemp(temperature) : "warm";
  const tierClasses = TIER_CLASSES[tier];

  return (
    <Card
      className={cn(
        "p-6 flex flex-col items-center justify-center text-center min-h-[180px]",
        className,
      )}
    >
      <ThermometerIcon className={cn("size-12 mb-3", tierClasses.icon)} />
      <div className={cn("text-4xl font-semibold tabular-nums", tierClasses.value)}>
        {temperature !== null ? `${Math.round(temperature)} °C` : "—"}
      </div>
      <div className="text-sm text-muted-foreground mt-2">Temperature</div>
    </Card>
  );
}
