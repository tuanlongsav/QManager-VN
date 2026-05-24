"use client";

import { useState } from "react";
import {
  CheckCircle2Icon,
  TriangleAlertIcon,
  XCircleIcon,
  MinusCircleIcon,
  EyeIcon,
  LockIcon,
} from "lucide-react";

import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Switch } from "@/components/ui/switch";
import { Label } from "@/components/ui/label";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { toast } from "sonner";

import { useAutolock } from "@/hooks/use-autolock";
import {
  AUTOLOCK_STATE_LABEL,
  type AutolockState,
} from "@/types/autolock";

// State badge color + icon mapping. Follows the Status Badge Pattern in CLAUDE.md.
const STATE_PRESENTATION: Record<
  AutolockState,
  { classes: string; Icon: typeof CheckCircle2Icon }
> = {
  idle: {
    classes: "bg-muted/50 text-muted-foreground border-muted-foreground/30",
    Icon: MinusCircleIcon,
  },
  watching: {
    classes: "bg-info/15 text-info hover:bg-info/20 border-info/30",
    Icon: EyeIcon,
  },
  locked: {
    classes: "bg-success/15 text-success hover:bg-success/20 border-success/30",
    Icon: LockIcon,
  },
  "signal-lost": {
    classes:
      "bg-warning/15 text-warning hover:bg-warning/20 border-warning/30",
    Icon: TriangleAlertIcon,
  },
};

export function AutolockCard() {
  const { config, status, isLoading, isSaving, error, save } = useAutolock();
  const [rsrpStable, setRsrpStable] = useState<string>("");
  const [sinrStable, setSinrStable] = useState<string>("");
  const [rsrpLost, setRsrpLost] = useState<string>("");
  const [samples, setSamples] = useState<string>("");
  const [thresholdsDirty, setThresholdsDirty] = useState(false);

  // Initialize threshold input fields when config first loads
  if (config && !thresholdsDirty && rsrpStable === "") {
    setRsrpStable(String(config.thresholds.rsrp_stable));
    setSinrStable(String(config.thresholds.sinr_stable));
    setRsrpLost(String(config.thresholds.rsrp_lost));
    setSamples(String(config.thresholds.samples));
  }

  if (isLoading || !config || !status) {
    return (
      <Card>
        <CardHeader>
          <CardTitle>Auto cell-lock</CardTitle>
          <CardDescription>
            Tự động khóa cell khi tín hiệu ổn định, tự động bỏ khóa khi tín hiệu yếu.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          <Skeleton className="h-6 w-32" />
          <Skeleton className="h-10 w-full" />
        </CardContent>
      </Card>
    );
  }

  const handleToggle = async (newEnabled: boolean) => {
    const ok = await save({ enabled: newEnabled });
    if (ok) {
      toast.success(newEnabled ? "Auto-lock đã bật" : "Auto-lock đã tắt");
    } else {
      toast.error("Không lưu được cấu hình auto-lock");
    }
  };

  const handleSaveThresholds = async () => {
    const ok = await save({
      rsrp_stable: Number(rsrpStable),
      sinr_stable: Number(sinrStable),
      rsrp_lost: Number(rsrpLost),
      samples: Number(samples),
    });
    if (ok) {
      toast.success("Đã cập nhật ngưỡng auto-lock");
      setThresholdsDirty(false);
    } else {
      toast.error("Không lưu được ngưỡng");
    }
  };

  const presentation = STATE_PRESENTATION[status.state];
  const { Icon } = presentation;

  return (
    <Card>
      <CardHeader>
        <CardTitle>Auto cell-lock</CardTitle>
        <CardDescription>
          Tự động khóa cell khi tín hiệu ổn định (RSRP &gt; {config.thresholds.rsrp_stable} dBm,
          SINR &gt; {config.thresholds.sinr_stable} dB trong {config.thresholds.samples} sample), tự động bỏ khóa khi tín hiệu rớt (RSRP &lt; {config.thresholds.rsrp_lost} dBm).
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-6">
        {/* State machine status */}
        <div className="flex flex-wrap items-center gap-3">
          <Badge variant="outline" className={presentation.classes}>
            <Icon className="size-3" />
            {AUTOLOCK_STATE_LABEL[status.state]}
          </Badge>
          {status.locked_pci && (
            <span className="text-sm text-muted-foreground">
              PCI {status.locked_pci}
              {status.locked_earfcn ? ` · EARFCN ${status.locked_earfcn}` : ""}
            </span>
          )}
          <span className="text-xs text-muted-foreground ml-auto">
            {status.message}
          </span>
        </div>

        {/* Enable toggle */}
        <div className="flex items-center justify-between gap-4">
          <div>
            <Label htmlFor="autolock-enabled" className="text-base">
              Bật auto-lock
            </Label>
            <p className="text-sm text-muted-foreground">
              Daemon chạy nền, không can thiệp khi đang khóa thủ công.
            </p>
          </div>
          <Switch
            id="autolock-enabled"
            checked={config.enabled}
            onCheckedChange={handleToggle}
            disabled={isSaving}
          />
        </div>

        {/* Threshold tuning */}
        <div className="space-y-3 rounded-md border border-border/60 p-4">
          <h4 className="text-sm font-medium">Ngưỡng (advanced)</h4>
          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-1">
              <Label htmlFor="rsrp-stable" className="text-xs">RSRP stable (dBm)</Label>
              <Input
                id="rsrp-stable"
                type="number"
                value={rsrpStable}
                onChange={(e) => {
                  setRsrpStable(e.target.value);
                  setThresholdsDirty(true);
                }}
              />
            </div>
            <div className="space-y-1">
              <Label htmlFor="sinr-stable" className="text-xs">SINR stable (dB)</Label>
              <Input
                id="sinr-stable"
                type="number"
                value={sinrStable}
                onChange={(e) => {
                  setSinrStable(e.target.value);
                  setThresholdsDirty(true);
                }}
              />
            </div>
            <div className="space-y-1">
              <Label htmlFor="rsrp-lost" className="text-xs">RSRP lost (dBm)</Label>
              <Input
                id="rsrp-lost"
                type="number"
                value={rsrpLost}
                onChange={(e) => {
                  setRsrpLost(e.target.value);
                  setThresholdsDirty(true);
                }}
              />
            </div>
            <div className="space-y-1">
              <Label htmlFor="samples" className="text-xs">Samples</Label>
              <Input
                id="samples"
                type="number"
                min={1}
                max={20}
                value={samples}
                onChange={(e) => {
                  setSamples(e.target.value);
                  setThresholdsDirty(true);
                }}
              />
            </div>
          </div>
          <div className="flex justify-end">
            <Button
              size="sm"
              onClick={handleSaveThresholds}
              disabled={!thresholdsDirty || isSaving}
            >
              Lưu ngưỡng
            </Button>
          </div>
        </div>

        {error && (
          <div className="flex items-center gap-2 text-sm text-destructive">
            <XCircleIcon className="size-4" />
            {error}
          </div>
        )}
      </CardContent>
    </Card>
  );
}
