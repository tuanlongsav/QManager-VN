"use client";

import Link from "next/link";
import { MailIcon } from "lucide-react";

import { Card } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { useSms } from "@/hooks/use-sms";
import { useT } from "@/hooks/use-i18n";
import { cn } from "@/lib/utils";

interface SmsReceivedWidgetProps {
  className?: string;
}

// =============================================================================
// SmsReceivedWidget — Inbox-count tile linking to SMS center (QManager-VN)
// =============================================================================
// Modeled after Simple Admin's "SMS Received: 0" top widget. Quectel modems
// don't track read/unread state, so we show the total count of messages in
// inbox storage — same convention as the reference UI. Click → SMS center
// for the full thread list.
// =============================================================================

export function SmsReceivedWidget({ className }: SmsReceivedWidgetProps) {
  const { data, isLoading } = useSms();
  const { t } = useT();
  const count = data?.messages?.length ?? 0;

  const body = (
    <Card
      className={cn(
        "p-6 flex flex-col items-center justify-center text-center min-h-[200px] h-full",
        "transition-colors hover:bg-accent/40",
        className,
      )}
    >
      <MailIcon className="size-12 mb-3 text-primary" />
      {isLoading && !data ? (
        <Skeleton className="h-10 w-16 mb-2" />
      ) : (
        <div className="text-4xl font-bold tabular-nums">{count}</div>
      )}
      <div className="text-sm font-semibold uppercase tracking-wide text-muted-foreground mt-2">
        {t("dashboard.smsReceived")}
      </div>
    </Card>
  );

  // Wrapping in Link keeps the widget keyboard-accessible (focusable) and
  // gives a single click target across the whole tile. Same UX as Simple
  // Admin which treats the count tile as a jump-to-inbox button.
  return (
    <Link
      href="/cellular/sms"
      aria-label={`Open SMS inbox (${count} message${count === 1 ? "" : "s"})`}
    >
      {body}
    </Link>
  );
}
