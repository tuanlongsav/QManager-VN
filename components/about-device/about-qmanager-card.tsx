"use client";

import Image from "next/image";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import QManagerLogo from "@/public/qmanager-logo.svg";
import packageJson from "@/package.json";
import { useT } from "@/hooks/use-i18n";

import type { AboutDeviceData } from "@/types/about-device";

// =============================================================================
// AboutQManagerCard — QManager info + network details
// =============================================================================

interface AboutQManagerCardProps {
  data: AboutDeviceData | null;
  isLoading: boolean;
}

const AboutQManagerCard = ({ data, isLoading }: AboutQManagerCardProps) => {
  const { t } = useT();
  const networkRows = [
    { label: t("aboutDevice.deviceIp"), value: data?.network.device_ip },
    { label: t("aboutDevice.lanGateway"), value: data?.network.lan_gateway },
    { label: t("aboutDevice.wwanIpv4"), value: data?.network.wan_ipv4 },
    { label: t("aboutDevice.wwanIpv6"), value: data?.network.wan_ipv6 },
    { label: t("aboutDevice.publicIpv4"), value: data?.network.public_ipv4 },
    { label: t("aboutDevice.publicIpv6"), value: data?.network.public_ipv6 },
  ];

  return (
    <Card className="@container/card">
      <CardHeader>
        <CardTitle className="text-2xl font-semibold">{t("aboutDevice.aboutQManagerTitle")}</CardTitle>
        <CardDescription>{t("aboutDevice.aboutQManagerDescription")}</CardDescription>
      </CardHeader>
      <CardContent>
        <div className="grid gap-6">
          {/* Logo */}
          <div className="flex items-center justify-center">
            <Image
              src={QManagerLogo}
              alt="QManager Logo"
              className="size-24"
              priority
            />
          </div>

          {/* Description */}
          <div className="grid gap-y-4">
            <p className="text-sm text-muted-foreground text-pretty leading-relaxed font-medium">
              {t("aboutDevice.aboutQManagerBody")}
            </p>

            {/* All rights reserved */}
            <p className="text-sm text-muted-foreground text-center">
              {t("aboutDevice.copyright", { year: new Date().getFullYear() })}
            </p>
          </div>

          {/* QManager version */}
          <div>
            <h3 className="text-xs font-medium text-muted-foreground uppercase tracking-wider mb-2">
              {t("aboutDevice.qmanagerSection")}
            </h3>
            <dl className="grid divide-y divide-border border-y border-border">
              <div className="flex items-center justify-between py-2">
                <dt className="text-sm font-semibold text-muted-foreground">
                  {t("aboutDevice.version")}
                </dt>
                <dd className="text-sm font-semibold tabular-nums">
                  {packageJson.version}
                </dd>
              </div>
            </dl>
          </div>

          {/* Network info */}
          <div>
            <h3 className="text-xs font-medium text-muted-foreground uppercase tracking-wider mb-2">
              {t("aboutDevice.networkSection")}
            </h3>
            <dl className="grid divide-y divide-border border-y border-border">
              {isLoading
                ? Array.from({ length: 6 }).map((_, i) => (
                    <div
                      key={i}
                      className="flex items-center justify-between py-2"
                    >
                      <Skeleton className="h-4 w-24" />
                      <Skeleton className="h-4 w-32" />
                    </div>
                  ))
                : networkRows.map((row) => (
                    <div
                      key={row.label}
                      className="flex items-center justify-between py-2"
                    >
                      <dt className="text-sm font-semibold text-muted-foreground">
                        {row.label}
                      </dt>
                      <dd
                        className="text-sm font-semibold tabular-nums min-w-0 truncate ml-4"
                        title={row.value || undefined}
                      >
                        {row.value || "-"}
                      </dd>
                    </div>
                  ))}
            </dl>
          </div>
        </div>
      </CardContent>
    </Card>
  );
};

export default AboutQManagerCard;
