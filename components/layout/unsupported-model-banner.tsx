"use client";

import { useState } from "react";
import { TriangleAlertIcon, XIcon } from "lucide-react";

import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { useHardwareInfo } from "@/hooks/use-hardware-info";
import { shouldShowUnsupportedBanner } from "@/lib/feature-gating";
import { GITHUB_ISSUES_URL } from "@/constants/github";
import { readStorageValueOrNull, writeStorageValue } from "@/lib/browser-storage";

const DISMISS_KEY = "qmanager_vn_unsupported_banner_dismissed";

/**
 * Remember/recall the dismissal without ever letting storage take the page down.
 *
 * Both go through lib/browser-storage rather than carrying their own try/catch.
 * This file used to hold a hand-rolled copy, and hand-rolled copies are what let
 * this crash class survive three rounds of fixes: each copy looked correct on
 * its own, and none of them was the one the next reviewer happened to read.
 *
 * Why it matters here specifically: the read runs in a useState initializer, a
 * throw from which nothing catches, and this banner renders inside the
 * dashboard tree — so one storage-blocked browser would mean a dashboard that
 * renders nothing at all.
 *
 * Both directions fail open toward the harmless side: an unreadable store reads
 * as "not dismissed" (the banner reappears), an unwritable one means the
 * dismissal lasts only for this mount. Forgetting a dismissal is an annoyance;
 * a blank dashboard on a headless modem is an outage.
 */
function readDismissedModel(): string | null {
  return readStorageValueOrNull("session", DISMISS_KEY);
}

function rememberDismissedModel(model: string): void {
  // Return value ignored on purpose: a dismissal that cannot be persisted just
  // does not survive a reload, and the in-memory state below still hides the
  // banner for the rest of this session.
  writeStorageValue("session", DISMISS_KEY, model);
}

/**
 * Banner shown when the detected modem model isn't in the tested set (GL / GLAA).
 *
 * Dismiss is per-session (sessionStorage, not localStorage) — we want the user
 * to see it once per session so they don't forget which tier their hardware is
 * on. Dismissals are scoped to a specific model so plugging in a different
 * modem mid-session re-surfaces the banner.
 */
export function UnsupportedModelBanner() {
  const { hardware } = useHardwareInfo();

  // Read the dismissal once, when the state is created. The prerender has no
  // sessionStorage and reports null; that pass can't render the banner anyway,
  // since `hardware` is still null until the fetch below it resolves — so no
  // hydration mismatch.
  const [dismissedFor, setDismissedFor] = useState<string | null>(
    readDismissedModel,
  );

  if (!shouldShowUnsupportedBanner(hardware)) return null;
  if (!hardware) return null;
  if (dismissedFor === hardware.model) return null;

  const dismiss = () => {
    rememberDismissedModel(hardware.model);
    setDismissedFor(hardware.model);
  };

  return (
    <Alert className="bg-warning/15 text-warning border-warning/30 mb-4">
      <TriangleAlertIcon className="size-4" />
      <AlertTitle>Modem chưa được kiểm chứng: {hardware.model}</AlertTitle>
      <AlertDescription className="text-warning/90">
        <div>
          QManager-VN chỉ được test chính thức trên RM520N-GL và RM520N-GLAA. Modem
          của bạn ({hardware.model}) thuộc tier <strong>{hardware.support_tier}</strong> —
          một số tính năng có thể không hoạt động.
        </div>
        <div className="mt-2 flex flex-wrap items-center gap-2">
          <a
            href={`${GITHUB_ISSUES_URL}/new?template=compatibility-report.md&title=${encodeURIComponent(`Compatibility report: ${hardware.model}`)}`}
            target="_blank"
            rel="noopener noreferrer"
            className="underline underline-offset-2 hover:opacity-80"
          >
            Báo cáo trạng thái trên GitHub Issues
          </a>
          <Button
            variant="ghost"
            size="sm"
            onClick={dismiss}
            className="ml-auto h-7 px-2 text-warning hover:bg-warning/20 hover:text-warning"
          >
            <XIcon className="size-3" />
            Bỏ qua
          </Button>
        </div>
      </AlertDescription>
    </Alert>
  );
}
