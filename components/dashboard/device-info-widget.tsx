"use client";

import { useState } from "react";
import Image from "next/image";

import { Card } from "@/components/ui/card";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import DeviceInformationCard from "@/components/about-device/device-information-card";
import { useAboutDevice } from "@/hooks/use-about-device";
import { useT } from "@/hooks/use-i18n";
import { cn } from "@/lib/utils";

interface DeviceInfoWidgetProps {
  className?: string;
}

// =============================================================================
// DeviceInfoWidget — Top-row device tile (QManager-VN F.2.L.3)
// =============================================================================
// Click → opens a modal containing the full Device Information card (model,
// manufacturer, firmware, IMEI, phone, etc.). The widget itself shows the
// same modem icon used on the About Device page, so the visual association
// is obvious. Mirrors the user's mental model: "the card with the 5G modem
// graphic on About Device is now also one of my dashboard tiles."
// =============================================================================

export function DeviceInfoWidget({ className }: DeviceInfoWidgetProps) {
  const [open, setOpen] = useState(false);
  const { data, isLoading, error, refresh } = useAboutDevice();
  const { t } = useT();
  const modelLabel = data?.device?.model?.trim() || "Modem";

  return (
    <>
      <Card
        onClick={() => setOpen(true)}
        onKeyDown={(e) => {
          if (e.key === "Enter" || e.key === " ") {
            e.preventDefault();
            setOpen(true);
          }
        }}
        role="button"
        tabIndex={0}
        aria-label="Open device information"
        className={cn(
          "p-6 flex flex-col items-center justify-center text-center min-h-[200px] h-full cursor-pointer",
          "transition-colors hover:bg-accent/40 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring",
          className,
        )}
      >
        <div className="size-12 bg-primary/15 rounded-full p-1.5 flex items-center justify-center mb-3">
          <Image
            src="/device-icon.svg"
            alt={modelLabel}
            width={48}
            height={48}
            className="size-full drop-shadow-md object-contain"
          />
        </div>
        <div className="text-2xl font-bold truncate max-w-full">{modelLabel}</div>
        <div className="text-sm font-semibold uppercase tracking-wide text-muted-foreground mt-2">
          {t("dashboard.deviceInformation")}
        </div>
        <div className="text-xs text-muted-foreground mt-2">{t("dashboard.tapForDetails")}</div>
      </Card>

      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent className="max-w-2xl max-h-[90vh] overflow-y-auto">
          <DialogHeader>
            <DialogTitle>{t("dashboard.deviceInformation")}</DialogTitle>
          </DialogHeader>
          <DeviceInformationCard
            data={data}
            isLoading={isLoading}
            error={error}
            onRetry={refresh}
          />
        </DialogContent>
      </Dialog>
    </>
  );
}
