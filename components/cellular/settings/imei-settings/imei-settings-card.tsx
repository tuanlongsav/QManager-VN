"use client";

import { useState, type FormEvent, type ChangeEvent } from "react";
import { toast } from "sonner";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import {
  Field,
  FieldDescription,
  FieldError,
  FieldGroup,
  FieldLabel,
  FieldSet,
} from "@/components/ui/field";
import {
  InputGroup,
  InputGroupAddon,
  InputGroupInput,
} from "@/components/ui/input-group";
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { Loader2, RotateCcwIcon, AlertTriangleIcon } from "lucide-react";
import { validateImei } from "@/lib/imei-utils";

interface IMEISettingsCardProps {
  currentImei: string | null;
  isLoading: boolean;
  isSaving: boolean;
  onSave: (imei: string) => Promise<boolean>;
  onReboot: () => Promise<boolean>;
}

const IMEISettingsCard = ({
  currentImei,
  isLoading,
  isSaving,
  onSave,
  onReboot,
}: IMEISettingsCardProps) => {
  // Holds `null` until the user types, so the input falls back to the fetched
  // IMEI — derived during render instead of synced through an effect.
  const [imeiEdit, setImeiEdit] = useState<string | null>(null);
  const [showRebootDialog, setShowRebootDialog] = useState(false);
  const [isRebooting, setIsRebooting] = useState(false);

  const imei = imeiEdit ?? currentImei ?? "";

  const isValidImei = validateImei(imei);
  const hasChanged = imei !== (currentImei ?? "");
  const showImeiError = imei.length > 0 && !isValidImei;

  const handleSave = async (e: FormEvent) => {
    e.preventDefault();

    if (!isValidImei) return;

    if (!hasChanged) {
      toast.info("No changes to save");
      return;
    }

    const success = await onSave(imei);
    if (success) {
      toast.success("IMEI saved — reboot required to apply");
      setShowRebootDialog(true);
    } else {
      toast.error("Failed to save IMEI");
    }
  };

  // Dropping the edit makes the input fall back to the fetched IMEI again.
  const handleReset = () => setImeiEdit(null);

  const handleReboot = async (e: React.MouseEvent) => {
    e.preventDefault(); // Keep dialog open to show rebooting state
    setIsRebooting(true);
    const sent = await onReboot();
    if (sent) {
      toast.success("Device is rebooting...");
    } else {
      toast.error("Reboot failed — restart the device manually");
      setIsRebooting(false);
    }
  };

  // Only allow digits in the input
  const handleImeiChange = (e: ChangeEvent<HTMLInputElement>) => {
    const value = e.target.value.replace(/\D/g, "").slice(0, 15);
    setImeiEdit(value);
  };

  if (isLoading) {
    return (
      <Card className="@container/card">
        <CardHeader>
          <CardTitle>IMEI Settings</CardTitle>
          <CardDescription>
            Please proceed with caution when modifying IMEI settings. Incorrect
            changes may lead to device malfunctions or legal issues.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <div className="grid gap-4">
            <div className="space-y-2">
              <Skeleton className="h-4 w-36" />
              <Skeleton className="h-9 w-full" />
              <Skeleton className="h-3 w-64" />
            </div>
            <div className="flex gap-2">
              <Skeleton className="h-9 w-28" />
              <Skeleton className="h-9 w-9" />
            </div>
          </div>
        </CardContent>
      </Card>
    );
  }

  return (
    <Card className="@container/card">
      <CardHeader>
        <CardTitle>IMEI Settings</CardTitle>
        <CardDescription>
          Change the device&apos;s IMEI identifier. A reboot is required after changes.
          Check your local regulations before modifying.
        </CardDescription>
      </CardHeader>
      <CardContent>
        <form className="grid gap-4" onSubmit={handleSave}>
          <div className="w-full">
            <FieldSet>
              <FieldGroup>
                <Field>
                  <FieldLabel htmlFor="device-imei-input">
                    Set Device IMEI
                  </FieldLabel>
                  <InputGroup>
                    <InputGroupInput
                      id="device-imei-input"
                      placeholder="Enter Device IMEI"
                      value={imei}
                      onChange={handleImeiChange}
                      maxLength={15}
                      inputMode="numeric"
                      disabled={isSaving}
                      aria-invalid={showImeiError}
                      aria-describedby={showImeiError ? "imei-error" : undefined}
                    />
                    <InputGroupAddon align="inline-start">
                      <Tooltip>
                        <TooltipTrigger asChild>
                          <button
                            type="button"
                            className="pl-1.5 inline-flex items-center"
                            aria-label="IMEI legal warning"
                          >
                            <AlertTriangleIcon className="text-muted-foreground size-4" />
                          </button>
                        </TooltipTrigger>
                        <TooltipContent>
                          <p>
                            IMEI modification regulations vary by country.
                            <br />
                            Check your local laws before changing the IMEI.
                          </p>
                        </TooltipContent>
                      </Tooltip>
                    </InputGroupAddon>
                  </InputGroup>
                  {showImeiError && (
                    <FieldError id="imei-error">
                      {imei.length !== 15
                        ? `IMEI must be exactly 15 digits (${imei.length}/15)`
                        : "IMEI failed Luhn checksum validation"}
                    </FieldError>
                  )}
                  <FieldDescription>
                    Changing the IMEI will require a device reboot to take
                    effect.
                  </FieldDescription>
                </Field>
              </FieldGroup>
            </FieldSet>
          </div>
          <div className="flex items-center gap-x-2">
            <Button
              type="submit"
              disabled={isSaving || !isValidImei || !hasChanged}
            >
              {isSaving ? (
                <>
                  <Loader2 className="size-4 animate-spin" />
                  Saving...
                </>
              ) : (
                "Write IMEI"
              )}
            </Button>
            <Button
              type="button"
              variant="outline"
              onClick={handleReset}
              disabled={isSaving}
              aria-label="Reset to saved values"
            >
              <RotateCcwIcon />
            </Button>
          </div>
        </form>

        {/* Reboot confirmation dialog */}
        <AlertDialog open={showRebootDialog} onOpenChange={(open) => {
          if (!isRebooting) setShowRebootDialog(open);
        }}>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>Reboot Required</AlertDialogTitle>
              <AlertDialogDescription>
                IMEI changes require a device reboot to take effect. Would you
                like to reboot now?
              </AlertDialogDescription>
            </AlertDialogHeader>
            <AlertDialogFooter>
              <AlertDialogCancel disabled={isRebooting}>
                Reboot Later
              </AlertDialogCancel>
              <AlertDialogAction
                disabled={isRebooting}
                onClick={handleReboot}
              >
                {isRebooting ? (
                  <>
                    <Loader2 className="size-4 animate-spin" />
                    Rebooting...
                  </>
                ) : (
                  "Reboot Now"
                )}
              </AlertDialogAction>
            </AlertDialogFooter>
          </AlertDialogContent>
        </AlertDialog>
      </CardContent>
    </Card>
  );
};

export default IMEISettingsCard;
