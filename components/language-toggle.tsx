"use client";

import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { useT } from "@/hooks/use-i18n";
import { cn } from "@/lib/utils";

interface LanguageToggleProps {
  className?: string;
  /** When true, render only the flag icon (no chevron, smaller). */
  compact?: boolean;
}

// Inline SVG flag fragments — keeps the toggle render path free of external
// network fetches and gives consistent rendering across Linux/Windows browsers
// that handle emoji flags differently.
function FlagVN({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 30 20" className={className} aria-hidden>
      <rect width="30" height="20" fill="#da251d" />
      <path
        d="M15 5 L16.76 10.42 L22.5 10.42 L17.87 13.76 L19.63 19.18 L15 15.84 L10.37 19.18 L12.13 13.76 L7.5 10.42 L13.24 10.42 Z"
        fill="#ffff00"
      />
    </svg>
  );
}

function FlagEN({ className }: { className?: string }) {
  // Union Jack — covers "English" generically (UK flag is the iconic English-language flag worldwide).
  return (
    <svg viewBox="0 0 60 30" className={className} aria-hidden>
      <rect width="60" height="30" fill="#012169" />
      <path d="M0 0 L60 30 M60 0 L0 30" stroke="#fff" strokeWidth="6" />
      <path d="M0 0 L60 30 M60 0 L0 30" stroke="#c8102e" strokeWidth="4" />
      <path d="M30 0 V30 M0 15 H60" stroke="#fff" strokeWidth="10" />
      <path d="M30 0 V30 M0 15 H60" stroke="#c8102e" strokeWidth="6" />
    </svg>
  );
}

// =============================================================================
// LanguageToggle — Flag dropdown for EN/VI switch (QManager-VN F.3.B)
// =============================================================================
// Sits next to the "QManager Admin" header label per user request. Persists
// preference via useT (localStorage `qmanager_vn_lang`). All useT consumers
// re-render on toggle thanks to the module-level event bus in the hook.
// =============================================================================
export function LanguageToggle({ className, compact = false }: LanguageToggleProps) {
  const { lang, setLang, t } = useT();
  const CurrentFlag = lang === "vi" ? FlagVN : FlagEN;

  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <Button
          variant="ghost"
          size={compact ? "icon" : "sm"}
          aria-label={t("common.language")}
          className={cn("gap-1.5", className)}
        >
          <CurrentFlag className={compact ? "size-5 rounded-sm" : "size-4 rounded-sm"} />
          {!compact && (
            <span className="text-xs font-semibold uppercase tracking-wide">
              {lang === "vi" ? "VI" : "EN"}
            </span>
          )}
        </Button>
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end" className="min-w-[160px]">
        <DropdownMenuItem
          onClick={() => setLang("vi")}
          className={lang === "vi" ? "bg-accent" : undefined}
        >
          <FlagVN className="size-4 rounded-sm" />
          {t("common.vietnamese")}
        </DropdownMenuItem>
        <DropdownMenuItem
          onClick={() => setLang("en")}
          className={lang === "en" ? "bg-accent" : undefined}
        >
          <FlagEN className="size-4 rounded-sm" />
          {t("common.english")}
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
