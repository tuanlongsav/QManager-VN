"use client";

import { useState } from "react";
import { TriangleAlertIcon, XIcon } from "lucide-react";

import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { useHardwareInfo } from "@/hooks/use-hardware-info";
import { shouldShowUnsupportedBanner } from "@/lib/feature-gating";
import { GITHUB_ISSUES_URL } from "@/constants/github";

const DISMISS_KEY = "qmanager_vn_unsupported_banner_dismissed";

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

  // Read the dismissal once, when the state is created. The `typeof window`
  // guard covers the static-export prerender, where there is no sessionStorage;
  // that prerendered pass can't render the banner anyway, since `hardware` is
  // still null until the fetch below it resolves — so no hydration mismatch.
  const [dismissedFor, setDismissedFor] = useState<string | null>(() =>
    typeof window === "undefined"
      ? null
      : window.sessionStorage.getItem(DISMISS_KEY),
  );

  if (!shouldShowUnsupportedBanner(hardware)) return null;
  if (!hardware) return null;
  if (dismissedFor === hardware.model) return null;

  const dismiss = () => {
    if (typeof window !== "undefined") {
      window.sessionStorage.setItem(DISMISS_KEY, hardware.model);
    }
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
