"use client";

import Image from "next/image";
import { Mail, ExternalLink, Heart } from "lucide-react";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { useT } from "@/hooks/use-i18n";

// =============================================================================
// Brand icons — not available in lucide-react
// =============================================================================

const DiscordIcon = ({ className }: { className?: string }) => (
  <svg
    viewBox="0 0 24 24"
    fill="currentColor"
    className={className}
    aria-hidden="true"
  >
    <path d="M20.317 4.37a19.791 19.791 0 0 0-4.885-1.515.074.074 0 0 0-.079.037c-.21.375-.444.864-.608 1.25a18.27 18.27 0 0 0-5.487 0 12.64 12.64 0 0 0-.617-1.25.077.077 0 0 0-.079-.037A19.736 19.736 0 0 0 3.677 4.37a.07.07 0 0 0-.032.027C.533 9.046-.32 13.58.099 18.057a.082.082 0 0 0 .031.057 19.9 19.9 0 0 0 5.993 3.03.078.078 0 0 0 .084-.028c.462-.63.874-1.295 1.226-1.994a.076.076 0 0 0-.041-.106 13.107 13.107 0 0 1-1.872-.892.077.077 0 0 1-.008-.128 10.2 10.2 0 0 0 .372-.292.074.074 0 0 1 .077-.01c3.928 1.793 8.18 1.793 12.062 0a.074.074 0 0 1 .078.01c.12.098.246.198.373.292a.077.077 0 0 1-.006.127 12.299 12.299 0 0 1-1.873.892.077.077 0 0 0-.041.107c.36.698.772 1.362 1.225 1.993a.076.076 0 0 0 .084.028 19.839 19.839 0 0 0 6.002-3.03.077.077 0 0 0 .032-.054c.5-5.177-.838-9.674-3.549-13.66a.061.061 0 0 0-.031-.03zM8.02 15.33c-1.183 0-2.157-1.085-2.157-2.419 0-1.333.956-2.419 2.157-2.419 1.21 0 2.176 1.095 2.157 2.42 0 1.333-.956 2.418-2.157 2.418zm7.975 0c-1.183 0-2.157-1.085-2.157-2.419 0-1.333.956-2.419 2.157-2.419 1.21 0 2.176 1.095 2.157 2.42 0 1.333-.947 2.418-2.157 2.418z" />
  </svg>
);

const WiseIcon = ({ className }: { className?: string }) => (
  <svg viewBox="0 0 24 24" fill="currentColor" className={className} aria-hidden="true">
    <path d="M13.553 0 9.3 13.401 6.235 4.136H0l5.696 15.728h7.209L24 0h-10.447z" />
    <path d="m13.856 19.864 2.974-8.216-3.558-2.302-4.206 10.518h4.79z" />
  </svg>
);

const PayPalIcon = ({ className }: { className?: string }) => (
  <svg viewBox="0 0 24 24" fill="currentColor" className={className} aria-hidden="true">
    <path d="M7.076 21.337H2.47a.641.641 0 0 1-.633-.74L4.944.901C5.026.382 5.474 0 5.998 0h7.46c2.57 0 4.578.543 5.69 1.81 1.01 1.15 1.304 2.42 1.012 4.287-.023.143-.047.288-.077.437-.983 5.05-4.349 6.797-8.647 6.797h-2.19c-.524 0-.968.382-1.05.9l-1.12 7.106zm14.146-14.42a3.35 3.35 0 0 0-.607-.541c-.013.076-.026.175-.041.254-.93 4.778-4.005 7.201-9.138 7.201h-2.19a.563.563 0 0 0-.556.479l-1.187 7.527h-.506l-.24 1.516a.56.56 0 0 0 .554.647h3.882c.46 0 .85-.334.922-.788.06-.26.76-4.852.816-5.09a.932.932 0 0 1 .923-.788h.58c3.76 0 6.705-1.528 7.565-5.946.36-1.847.174-3.388-.777-4.471z" />
  </svg>
);

// =============================================================================
// SupportComponent — Contact, Community, and Donate cards
// =============================================================================

const SupportComponent = () => {
  const { t } = useT();

  return (
    <div className="@container/main mx-auto p-2">
      <div className="mb-6">
        <h1 className="text-3xl font-bold mb-2">{t("support.heading")}</h1>
        <p className="text-muted-foreground">{t("support.description")}</p>
      </div>
      <div className="grid grid-cols-1 @3xl/main:grid-cols-2 @6xl/main:grid-cols-3 grid-flow-row gap-4">
        {/* Contact Card */}
        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <Mail className="h-5 w-5 text-muted-foreground" />
              {t("support.contactTitle")}
            </CardTitle>
            <CardDescription>{t("support.contactDescription")}</CardDescription>
          </CardHeader>
          <CardContent>
            <div className="grid gap-6">
              <p className="text-sm text-muted-foreground leading-relaxed">
                {t("support.contactBody")}
              </p>
              <div>
                <dl className="grid divide-y divide-border border-y border-border">
                  <div className="flex items-center justify-between py-2">
                    <dt className="text-sm font-semibold text-muted-foreground">
                      {t("support.email")}
                    </dt>
                    <dd className="text-sm font-semibold min-w-0">
                      <a
                        href="mailto:russel.yasol@gmail.com"
                        className="inline-flex items-center gap-1.5 py-1 text-primary hover:underline underline-offset-4 truncate"
                        title="russel.yasol@gmail.com"
                      >
                        russel.yasol@gmail.com
                      </a>
                    </dd>
                  </div>
                  <div className="flex items-center justify-between py-2">
                    <dt className="text-sm font-semibold text-muted-foreground">
                      {t("support.github")}
                    </dt>
                    <dd className="text-sm font-semibold">
                      <a
                        href="https://github.com/dr-dolomite"
                        target="_blank"
                        rel="noopener noreferrer"
                        className="inline-flex items-center gap-1.5 py-1 text-primary hover:underline underline-offset-4"
                      >
                        dr-dolomite
                        <ExternalLink className="h-3.5 w-3.5" />
                      </a>
                    </dd>
                  </div>
                </dl>
              </div>
            </div>
          </CardContent>
        </Card>

        {/* Community Card */}
        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <DiscordIcon className="h-5 w-5 text-muted-foreground" />
              {t("support.communityTitle")}
            </CardTitle>
            <CardDescription>{t("support.communityDescription")}</CardDescription>
          </CardHeader>
          <CardContent>
            <div className="grid gap-6">
              <p className="text-sm text-muted-foreground leading-relaxed">
                {t("support.communityBody")}
              </p>
              <div className="flex flex-col items-center gap-4">
                <div className="rounded-lg border border-border bg-muted p-2">
                  <Image
                    src="/discord-qr.svg"
                    alt="QR code for QManager Discord server invite"
                    width={192}
                    height={192}
                    className="size-48"
                  />
                </div>
                <a
                  href="https://discord.iamromulan.dev/"
                  target="_blank"
                  rel="noopener noreferrer"
                  className="inline-flex items-center gap-1.5 py-1 text-sm font-semibold text-primary hover:underline underline-offset-4"
                >
                  discord.iamromulan.dev/
                  <ExternalLink className="h-3.5 w-3.5" />
                </a>
              </div>
            </div>
          </CardContent>
        </Card>

        {/* Donate Card */}
        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <Heart className="h-5 w-5 text-muted-foreground" />
              {t("support.donateTitle")}
            </CardTitle>
            <CardDescription>{t("support.donateDescription")}</CardDescription>
          </CardHeader>
          <CardContent>
            <div className="grid gap-3 text-sm text-pretty leading-relaxed">
              <p className="font-medium">{t("support.donateGreeting")}</p>
              <p className="text-muted-foreground">{t("support.donateMessage")}</p>
              <p className="font-medium">{t("support.donateThanks")}</p>
              <p className="text-xs text-muted-foreground">
                {t("support.donateSponsorsPrefix")}
                <a
                  href="https://github.com/sponsors/dr-dolomite"
                  target="_blank"
                  rel="noopener noreferrer"
                  className="underline underline-offset-2 hover:text-foreground transition-colors"
                >
                  {t("support.donateSponsorsLinkLabel")}
                </a>
                {t("support.donateSponsorsSuffix")}
              </p>
              <div className="flex flex-row items-center gap-2 pt-2">
                <Button
                  asChild
                  size="sm"
                  className="bg-[#163300] hover:bg-[#1f4a00] text-white"
                >
                  <a
                    href="https://wise.com/pay/business/blackcatdev?currency=USD"
                    target="_blank"
                    rel="noopener noreferrer"
                  >
                    <WiseIcon className="size-4" />
                    Wise
                  </a>
                </Button>
                <Button
                  asChild
                  size="sm"
                  className="bg-[#003087] hover:bg-[#002070] text-white"
                >
                  <a
                    href="https://paypal.me/iamrusss"
                    target="_blank"
                    rel="noopener noreferrer"
                  >
                    <PayPalIcon className="size-4" />
                    PayPal
                  </a>
                </Button>
              </div>
            </div>
          </CardContent>
        </Card>
      </div>
    </div>
  );
};

export default SupportComponent;
