"use client";

import { LayoutGridIcon, LayoutListIcon } from "lucide-react";

import { useUiMode } from "@/hooks/use-ui-mode";
import { Button } from "@/components/ui/button";
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from "@/components/ui/tooltip";

/**
 * Toggle button for switching dashboard density between Simple and Pro modes.
 *
 * - Simple: layout gọn với card cốt lõi (network status, device, live latency)
 * - Pro: layout full với detail cards, device metrics, signal history chart
 *
 * Preference persisted in localStorage via useUiMode. Toggle is a single icon
 * button to keep the dashboard header light.
 */
export function UiModeToggle() {
  const { isPro, toggleMode } = useUiMode();
  const Icon = isPro ? LayoutGridIcon : LayoutListIcon;
  const next = isPro ? "Simple" : "Pro";

  return (
    <Tooltip>
      <TooltipTrigger asChild>
        <Button
          variant="outline"
          size="sm"
          onClick={toggleMode}
          aria-label={`Switch to ${next} mode`}
        >
          <Icon className="size-4" />
          <span className="hidden sm:inline">{isPro ? "Pro" : "Simple"}</span>
        </Button>
      </TooltipTrigger>
      <TooltipContent>
        Switch to {next} mode
      </TooltipContent>
    </Tooltip>
  );
}
