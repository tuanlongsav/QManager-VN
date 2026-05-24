"use client";

import { Moon, Sun, Monitor } from "lucide-react";
import { useTheme } from "next-themes";

import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { useT } from "@/hooks/use-i18n";
import { cn } from "@/lib/utils";

interface ThemeToggleProps {
  className?: string;
  /** When true, render only the icon (no chevron / label). Matches LanguageToggle compact. */
  compact?: boolean;
}

// =============================================================================
// ThemeToggle — Light / Dark / System dropdown for sidebar header
// =============================================================================
// Sits next to LanguageToggle in the sidebar header. Trigger icon uses the
// CSS-only Sun/Moon swap (dark:hidden / hidden dark:block) so we don't fight
// next-themes SSR hydration. The dropdown items reflect the raw `theme`
// preference (light/dark/system), not the resolved theme — so "System" can be
// chosen explicitly. Active item is highlighted via bg-accent.
// =============================================================================
export function ThemeToggle({ className, compact = false }: ThemeToggleProps) {
  const { theme, setTheme } = useTheme();
  const { t } = useT();

  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <Button
          variant="ghost"
          size={compact ? "icon" : "sm"}
          aria-label={t("common.theme")}
          className={cn("gap-1.5", className)}
        >
          <Sun className={cn(compact ? "size-5" : "size-4", "dark:hidden")} />
          <Moon className={cn(compact ? "size-5" : "size-4", "hidden dark:block")} />
        </Button>
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end" className="min-w-[160px]">
        <DropdownMenuItem
          onClick={() => setTheme("light")}
          className={theme === "light" ? "bg-accent" : undefined}
        >
          <Sun className="size-4" />
          {t("common.lightTheme")}
        </DropdownMenuItem>
        <DropdownMenuItem
          onClick={() => setTheme("dark")}
          className={theme === "dark" ? "bg-accent" : undefined}
        >
          <Moon className="size-4" />
          {t("common.darkTheme")}
        </DropdownMenuItem>
        <DropdownMenuItem
          onClick={() => setTheme("system")}
          className={theme === "system" ? "bg-accent" : undefined}
        >
          <Monitor className="size-4" />
          {t("common.systemTheme")}
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
