"use client";

import React from "react";
import { motion } from "motion/react";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import {
  Accordion,
  AccordionContent,
  AccordionItem,
  AccordionTrigger,
} from "@/components/ui/accordion";
import { Badge } from "@/components/ui/badge";
import { Skeleton } from "@/components/ui/skeleton";

import type { CarrierComponent } from "@/types/modem-status";
import {
  getSignalQuality,
  signalToProgress,
  RSRP_THRESHOLDS,
  RSRQ_THRESHOLDS,
  SINR_THRESHOLDS,
  RSSI_THRESHOLDS,
} from "@/types/modem-status";
import {
  getDLFrequency,
  getULFrequency,
  formatFrequency,
  getBandName,
  getDuplexMode,
} from "@/lib/earfcn";
import {
  getValueColorClass,
  getQualityLabel,
} from "./signal-card-utils";
import { cn } from "@/lib/utils";

// =============================================================================
// RatPrimaryCard — Per-RAT carrier-band accordion (QManager-VN F.2.L.1)
// =============================================================================
// Replaces the old SignalStatusCard-based 4G/5G dashboard cards with the
// richer "Active Cellular Bands" accordion UX from the deleted Cellular
// Information page. Each card filters carrier_components to a single
// technology (LTE for 4G card, NR for 5G card), so the user gets:
//
//   - Compact header per band (collapsed by default for SCC, primary expanded)
//   - Full signal metrics with progress bars when expanded
//   - Per-row quality tier label (Best / Good / Fair / Poor) consistent with
//     the rest of the dashboard
//
// User feedback v0.3.2-vn:
//   "Sửa 4G Primary Status và 5G Primary Status để sử dụng và trình bày
//    giống Active Cellular Bands … trình bày riêng 2 section mà không
//    chung và cuộn nhỏ lại phải mở rộng ra xem."
// =============================================================================

interface RatPrimaryCardProps {
  /** Display title — usually "4G Primary Status" or "5G Primary Status" */
  title: string;
  /** Card description shown under the title */
  description?: string;
  /** Carrier components from useModemStatus → data.network.carrier_components */
  carrierComponents: CarrierComponent[] | null;
  /** Filter to this technology */
  technology: "LTE" | "NR";
  isLoading: boolean;
}

function techBadgeClass(tech: "LTE" | "NR"): string {
  return tech === "NR"
    ? "bg-blue-500 hover:bg-blue-500 text-white"
    : "bg-emerald-500 hover:bg-emerald-500 text-white";
}

function fmtSignal(value: number | null, unit: string): string {
  if (value === null || value === undefined) return "-";
  return `${value} ${unit}`;
}

function AnimatedProgress({ value }: { value: number }) {
  return (
    <div className="w-20 @[350px]/card:w-28 h-2 overflow-hidden rounded-full bg-secondary">
      <motion.div
        className="h-full rounded-full bg-primary"
        initial={{ scaleX: 0 }}
        animate={{ scaleX: value / 100 }}
        style={{ originX: 0 }}
        transition={{ type: "spring", stiffness: 180, damping: 24 }}
      />
    </div>
  );
}

/** Signal metric row with progress bar + quality tier label */
function SignalRow({
  label,
  value,
  unit,
  progress,
  quality,
}: {
  label: string;
  value: number | null;
  unit: string;
  progress: number;
  quality: "excellent" | "good" | "fair" | "poor" | "none";
}) {
  const colorClass = getValueColorClass(quality);
  const tierLabel = getQualityLabel(quality);
  return (
    <div className="flex items-center justify-between">
      <dt className="text-sm font-semibold text-muted-foreground">{label}</dt>
      <dd className="flex items-center gap-2.5">
        {tierLabel && (
          <span
            className={cn(
              "text-xs font-semibold uppercase tracking-wide",
              colorClass,
            )}
          >
            {tierLabel}
          </span>
        )}
        <AnimatedProgress value={progress} />
        <span className={cn("text-sm font-bold w-20 text-right tabular-nums", colorClass)}>
          {fmtSignal(value, unit)}
        </span>
      </dd>
    </div>
  );
}

function InfoRow({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex items-center justify-between">
      <dt className="text-sm font-semibold text-muted-foreground">{label}</dt>
      <dd className="text-sm font-bold">{value}</dd>
    </div>
  );
}

export function RatPrimaryCard({
  title,
  description,
  carrierComponents,
  technology,
  isLoading,
}: RatPrimaryCardProps) {
  if (isLoading) {
    return (
      <Card className="@container/card h-full">
        <CardHeader>
          <CardTitle>{title}</CardTitle>
          {description && <CardDescription>{description}</CardDescription>}
        </CardHeader>
        <CardContent className="space-y-3">
          <Skeleton className="h-12 w-full" />
          <Skeleton className="h-12 w-full" />
        </CardContent>
      </Card>
    );
  }

  const components = (carrierComponents ?? []).filter(
    (cc) => cc.technology === technology,
  );

  if (components.length === 0) {
    return (
      <Card className="@container/card h-full">
        <CardHeader>
          <CardTitle>{title}</CardTitle>
          <CardDescription>
            {description ??
              (technology === "NR"
                ? "No active 5G carrier."
                : "No active LTE carrier.")}
          </CardDescription>
        </CardHeader>
        <CardContent>
          <p className="text-sm text-muted-foreground text-center py-6">
            {technology === "NR"
              ? "Modem chưa kết nối NR. Carrier aggregation cập nhật mỗi ~30 giây."
              : "Modem chưa kết nối LTE. Carrier aggregation cập nhật mỗi ~30 giây."}
          </p>
        </CardContent>
      </Card>
    );
  }

  return (
    <Card className="@container/card h-full">
      <CardHeader>
        <CardTitle>{title}</CardTitle>
        <CardDescription>
          {description ??
            `${components.length} active carrier${components.length !== 1 ? "s" : ""}. ` +
              "Expand to see detailed signal metrics."}
        </CardDescription>
      </CardHeader>
      <CardContent>
        <Accordion
          type="single"
          collapsible
          className="w-full"
          defaultValue="item-0"
        >
          <motion.div
            initial="hidden"
            animate="visible"
            variants={{ hidden: {}, visible: { transition: { staggerChildren: 0.07 } } }}
          >
            {components.map((cc, idx) => {
              const rsrpQuality = getSignalQuality(cc.rsrp, RSRP_THRESHOLDS);
              const rsrqQuality = getSignalQuality(cc.rsrq, RSRQ_THRESHOLDS);
              const sinrQuality = getSignalQuality(cc.sinr, SINR_THRESHOLDS);
              const rssiQuality =
                cc.rssi !== null ? getSignalQuality(cc.rssi, RSSI_THRESHOLDS) : "none";

              return (
                <motion.div
                  key={`${cc.band}-${cc.pci}-${idx}`}
                  variants={{
                    hidden: { opacity: 0, y: 8 },
                    visible: { opacity: 1, y: 0 },
                  }}
                  transition={{ duration: 0.22, ease: "easeOut" }}
                >
                  <AccordionItem value={`item-${idx}`}>
                    <AccordionTrigger className="font-bold">
                      <div className="flex items-center gap-2 flex-wrap">
                        <Badge
                          className={`text-xs rounded-full ${techBadgeClass(cc.technology)}`}
                        >
                          {cc.type} {getDuplexMode(cc.band, cc.technology)}
                        </Badge>
                        <div className="flex items-center gap-1.5">
                          <p className="text-sm font-bold">
                            {cc.technology} {cc.band}
                          </p>
                          <span className="text-sm text-muted-foreground">–</span>
                          <p className="text-sm">{cc.earfcn}</p>
                        </div>
                      </div>
                    </AccordionTrigger>
                    <AccordionContent>
                      <motion.dl
                        className="grid gap-1.5 text-base"
                        initial="hidden"
                        animate="visible"
                        variants={{
                          hidden: {},
                          visible: { transition: { staggerChildren: 0.05 } },
                        }}
                      >
                        <SignalRow
                          label="RSRP"
                          value={cc.rsrp}
                          unit="dBm"
                          progress={signalToProgress(cc.rsrp, RSRP_THRESHOLDS)}
                          quality={rsrpQuality}
                        />
                        <SignalRow
                          label="RSRQ"
                          value={cc.rsrq}
                          unit="dB"
                          progress={signalToProgress(cc.rsrq, RSRQ_THRESHOLDS)}
                          quality={rsrqQuality}
                        />
                        <SignalRow
                          label={cc.technology === "NR" ? "SNR" : "SINR"}
                          value={cc.sinr}
                          unit="dB"
                          progress={signalToProgress(cc.sinr, SINR_THRESHOLDS)}
                          quality={sinrQuality}
                        />
                        {cc.technology === "LTE" && cc.rssi !== null && (
                          <SignalRow
                            label="RSSI"
                            value={cc.rssi}
                            unit="dBm"
                            progress={signalToProgress(cc.rssi, RSSI_THRESHOLDS)}
                            quality={rssiQuality}
                          />
                        )}
                        <InfoRow
                          label="Band Name"
                          value={getBandName(cc.band, cc.technology)}
                        />
                        <InfoRow
                          label="UL Frequency"
                          value={
                            cc.earfcn !== null
                              ? formatFrequency(
                                  getULFrequency(cc.earfcn, cc.technology, cc.band),
                                )
                              : "-"
                          }
                        />
                        <InfoRow
                          label="DL Frequency"
                          value={
                            cc.earfcn !== null
                              ? formatFrequency(
                                  getDLFrequency(cc.earfcn, cc.technology),
                                )
                              : "-"
                          }
                        />
                        <InfoRow
                          label="Bandwidth"
                          value={
                            cc.bandwidth_mhz > 0 ? `${cc.bandwidth_mhz} MHz` : "-"
                          }
                        />
                        <InfoRow
                          label="PCI"
                          value={cc.pci !== null ? String(cc.pci) : "-"}
                        />
                      </motion.dl>
                    </AccordionContent>
                  </AccordionItem>
                </motion.div>
              );
            })}
          </motion.div>
        </Accordion>
      </CardContent>
    </Card>
  );
}
