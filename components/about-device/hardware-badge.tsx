"use client";

import {
  CheckCircle2Icon,
  TriangleAlertIcon,
  XCircleIcon,
  CpuIcon,
} from "lucide-react";

import { Badge } from "@/components/ui/badge";
import { useHardwareInfo } from "@/hooks/use-hardware-info";
import { SUPPORT_TIER_LABEL } from "@/types/hardware-info";

/**
 * Compact badge showing detected modem model + support tier.
 *
 * Render anywhere the user might want quick visual confirmation of what
 * hardware QManager-VN sees. Common spots: about-device page, dashboard
 * footer. Self-fetching via useHardwareInfo (cached at module level so
 * multiple instances don't multiply requests).
 */
export function HardwareBadge() {
  const { hardware, isLoading } = useHardwareInfo();

  if (isLoading || !hardware) {
    return (
      <Badge variant="outline" className="bg-muted/50 text-muted-foreground border-muted-foreground/30">
        <CpuIcon className="size-3" />
        Detecting hardware…
      </Badge>
    );
  }

  const tierClasses = (() => {
    switch (hardware.support_tier) {
      case "primary":
      case "tested":
        return "bg-success/15 text-success hover:bg-success/20 border-success/30";
      case "best-effort":
        return "bg-warning/15 text-warning hover:bg-warning/20 border-warning/30";
      case "unsupported":
      default:
        return "bg-destructive/15 text-destructive hover:bg-destructive/20 border-destructive/30";
    }
  })();

  const TierIcon = (() => {
    switch (hardware.support_tier) {
      case "primary":
      case "tested":
        return CheckCircle2Icon;
      case "best-effort":
        return TriangleAlertIcon;
      case "unsupported":
      default:
        return XCircleIcon;
    }
  })();

  return (
    <Badge
      variant="outline"
      className={tierClasses}
      title={`${hardware.model} · ${hardware.soc} · ${SUPPORT_TIER_LABEL[hardware.support_tier]}\nFirmware: ${hardware.firmware || "unknown"}`}
    >
      <TierIcon className="size-3" />
      {hardware.model === "unknown" ? "Unknown model" : hardware.model}
      <span className="opacity-60">·</span>
      <span className="text-[10px] uppercase tracking-wide opacity-80">
        {SUPPORT_TIER_LABEL[hardware.support_tier]}
      </span>
    </Badge>
  );
}
