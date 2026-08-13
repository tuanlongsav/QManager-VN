"use client";

import { useCallback, useEffect, useState } from "react";
import { motion } from "motion/react";
import { EyeIcon, EyeOffIcon } from "lucide-react";
import { useLogin } from "@/hooks/use-auth";
import { useT } from "@/hooks/use-i18n";
import { LanguageToggle } from "@/components/language-toggle";
import { Button } from "@/components/ui/button";
import {
  Field,
  FieldDescription,
  FieldGroup,
  FieldLabel,
} from "@/components/ui/field";
import { Input } from "@/components/ui/input";
import { Spinner } from "@/components/ui/spinner";

// =============================================================================
// Backend error code -> translation key
// =============================================================================
// The login CGI's `error` field is a machine-readable code, not prose
// ("invalid_password", "rate_limited" — see auth/login.sh); its `detail` field
// is an English sentence. useLogin keeps them apart, so `result.code` is what
// this map keys on. Matching the sentence instead would break silently the day
// someone reworded a string in login.sh; an unrecognized code merely degrades
// to the generic localized message and logs the backend's own words for a
// maintainer.
//
// A Map rather than an object literal: the key comes off the wire, and `Map`
// has no prototype chain for a value like "constructor" to fall through into.
//
// Two codes login.sh can emit are deliberately absent — `password_too_short`
// and `password_mismatch` are setup-mode only, and useLogin's `login()` never
// sends `confirm`, so the CGI answers `setup_required` instead of reaching
// them. `setup_required` itself is handled before this lookup.
const LOGIN_ERROR_KEYS = new Map<string, string>([
  ["invalid_password", "login.invalidPassword"],
  ["missing_password", "login.missingPassword"],
  ["no_body", "login.requestFailed"],
  // The 429 normally arrives with retry_after and drives the countdown below;
  // this covers the malformed case where that field is missing, leaving no
  // number to count down from.
  ["rate_limited", "login.rateLimitedUnknown"],
  // Not a backend code — useLogin's own sentinel for a request that never
  // came back as parseable JSON.
  ["connection_failed", "login.connectionFailed"],
]);

// =============================================================================
// LoginComponent
// =============================================================================

export default function LoginComponent() {
  const { status, login } = useLogin();
  const { t } = useT();

  const [password, setPassword] = useState("");
  const [showPassword, setShowPassword] = useState(false);
  const [error, setError] = useState("");
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [retryAfter, setRetryAfter] = useState(0);

  const wasOffline =
    typeof window !== "undefined" &&
    new URLSearchParams(window.location.search).get("reason") === "offline";

  // Redirect to dedicated onboarding wizard when this is a fresh install
  useEffect(() => {
    if (status === "setup_required") {
      window.location.href = "/setup/";
    }
  }, [status]);

  // Rate limit countdown timer
  useEffect(() => {
    if (retryAfter <= 0) return;
    const id = setInterval(() => {
      setRetryAfter((prev) => (prev <= 1 ? 0 : prev - 1));
    }, 1000);
    return () => clearInterval(id);
  }, [retryAfter]);

  const handleSubmit = useCallback(
    async (e: React.FormEvent) => {
      e.preventDefault();
      setError("");
      setIsSubmitting(true);
      try {
        const result = await login(password);
        if (result.success) return;

        // useLogin already flipped status to "setup_required", so the redirect
        // effect above takes over and this component renders the spinner
        // instead of the form — there is no error left to show.
        if (result.code === "setup_required") return;

        if (result.retry_after) {
          setRetryAfter(result.retry_after);
          setError(t("login.rateLimited", { seconds: result.retry_after }));
          return;
        }

        const mapped = result.code
          ? LOGIN_ERROR_KEYS.get(result.code)
          : undefined;
        if (!mapped) {
          // Neither the code nor the backend's English sentence is fit for the
          // UI, but a maintainer with the console open should still see both.
          console.warn(
            "[login] unmapped backend error:",
            result.code ?? "(no code)",
            result.detail ?? ""
          );
        }
        setError(t(mapped ?? "login.invalidPassword"));
      } finally {
        setIsSubmitting(false);
      }
    },
    [password, login, t]
  );

  // Show spinner while detecting setup status or during redirect to /setup/
  if (status === "loading" || status === "setup_required") {
    return (
      <div className="flex flex-col items-center gap-4 py-12">
        <Spinner className="size-6" />
      </div>
    );
  }

  return (
    <motion.div
      className="flex flex-col gap-6"
      initial={{ opacity: 0, y: 12 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ duration: 0.3, ease: "easeOut" }}
    >
      {/* Language picker — this is the first screen a user meets, and the only
          other switch lives in the sidebar, i.e. behind authentication. */}
      <div className="flex justify-end">
        <LanguageToggle compact />
      </div>

      {/* Offline session-loss banner */}
      {wasOffline && (
        <div className="rounded-lg border border-warning/30 bg-warning/10 px-4 py-3 text-sm text-warning">
          {t("login.sessionEnded")}
        </div>
      )}

      <form onSubmit={handleSubmit}>
        <FieldGroup>
          <div className="flex flex-col items-center gap-2 text-center">
            <div className="flex size-16 p-1 items-center justify-center rounded-md">
              <img
                src="/qmanager-logo.svg"
                alt={t("login.logoAlt")}
                className="size-full"
              />
            </div>
            <h1 className="text-xl font-bold">{t("login.welcome")}</h1>
            <FieldDescription>{t("login.subtitle")}</FieldDescription>
          </div>

          <Field>
            <FieldLabel htmlFor="password">{t("login.passwordLabel")}</FieldLabel>
            <div className="relative">
              <Input
                id="password"
                type={showPassword ? "text" : "password"}
                placeholder={t("login.passwordPlaceholder")}
                autoComplete="current-password"
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                required
                disabled={isSubmitting}
                className="pr-10"
              />
              <Button
                type="button"
                variant="ghost"
                size="icon-sm"
                className="absolute right-1 top-1/2 -translate-y-1/2 text-muted-foreground hover:text-foreground"
                onClick={() => setShowPassword((v) => !v)}
                tabIndex={-1}
                aria-label={
                  showPassword ? t("login.hidePassword") : t("login.showPassword")
                }
              >
                {showPassword ? <EyeOffIcon className="size-4" /> : <EyeIcon className="size-4" />}
              </Button>
            </div>
          </Field>

          {error && (
            <p role="alert" className="text-sm text-destructive">
              {error}
            </p>
          )}

          <Field>
            <Button
              type="submit"
              className="w-full"
              disabled={isSubmitting || retryAfter > 0}
            >
              {isSubmitting ? (
                <>
                  <Spinner className="mr-2" />
                  {t("login.submitting")}
                </>
              ) : retryAfter > 0 ? (
                t("login.locked", { seconds: retryAfter })
              ) : (
                t("login.submit")
              )}
            </Button>
          </Field>
        </FieldGroup>
      </form>
      <FieldDescription className="px-6 text-center">
        {t("login.footer")}
      </FieldDescription>
    </motion.div>
  );
}
