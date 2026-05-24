"use client";

import React from "react";
import { motion, type Variants } from "motion/react";
import { useModemStatus } from "@/hooks/use-modem-status";
import { useAboutDevice } from "@/hooks/use-about-device";
import { useT } from "@/hooks/use-i18n";
import { NetworkStatusCompact } from "./network-status-compact";
import { TemperatureWidget } from "./temperature-widget";
import { SmsReceivedWidget } from "./sms-received-widget";
import { InternetQualityWidget } from "./internet-quality-widget";
import { DeviceInfoWidget } from "./device-info-widget";
import { RatPrimaryCard } from "./rat-primary-card";
import { AutolockCard } from "@/components/cellular/tower-locking/autolock-card";
import RecentActivitiesComponent from "./recent-activities";
import DeviceMetricsComponent from "./device-metrics";
import CellDataComponent from "@/components/cellular/cell-data";

const DEFAULT_POLL_MS = 2000;
const POLL_BUFFER_MS = 250;

const containerVariants: Variants = {
  hidden: {},
  visible: { transition: { staggerChildren: 0.06 } },
};

const itemVariants: Variants = {
  hidden: { opacity: 0, y: 8 },
  visible: {
    opacity: 1,
    y: 0,
    transition: { duration: 0.25, ease: "easeOut" },
  },
};

const HomeComponent = () => {
  const [pollInterval, setPollInterval] = React.useState<number>(DEFAULT_POLL_MS);
  const { data, isLoading, isStale, error } = useModemStatus({ pollInterval });
  const { data: aboutDevice } = useAboutDevice();
  const { t } = useT();

  const daemonIntervalSec = data?.connectivity?.history_interval_sec;
  React.useEffect(() => {
    if (!daemonIntervalSec || daemonIntervalSec <= 0) return;
    const next = daemonIntervalSec * 1000 + POLL_BUFFER_MS;
    setPollInterval((prev) => (prev === next ? prev : next));
  }, [daemonIntervalSec]);

  void isStale;

  return (
    <div className="grid grid-cols-1 gap-6 px-4 lg:px-6" aria-live="polite" aria-atomic="false">
      {error && !isLoading && (
        <div role="alert" className="rounded-lg bg-destructive/10 px-4 py-3 text-sm text-destructive">
          {t("dashboard.modemUnreachable")}
        </div>
      )}

      {/* === Top row — 5 same-size widgets (QManager-VN F.2.L.4) ===
          NetworkStatus / Temperature / SMS / InternetQuality / DeviceInfo.
          Stack 1-col on phones, 2x3 on tablets, 5x1 on desktop. */}
      <motion.div
        className="grid grid-cols-1 @md/main:grid-cols-2 @4xl/main:grid-cols-5 gap-4"
        variants={containerVariants}
        initial="hidden"
        animate="visible"
      >
        <motion.div variants={itemVariants} className="h-full *:data-[slot=card]:h-full">
          <NetworkStatusCompact
            network={data?.network ?? null}
            device={data?.device ?? null}
            aboutDevice={aboutDevice ?? null}
            connectivity={data?.connectivity ?? null}
            modemReachable={data?.modem_reachable ?? false}
            isLoading={isLoading}
          />
        </motion.div>
        <motion.div variants={itemVariants} className="h-full *:data-[slot=card]:h-full">
          <TemperatureWidget
            temperature={data?.device?.temperature ?? null}
            isLoading={isLoading}
          />
        </motion.div>
        <motion.div variants={itemVariants} className="h-full *:data-[slot=card]:h-full">
          <SmsReceivedWidget />
        </motion.div>
        <motion.div variants={itemVariants} className="h-full *:data-[slot=card]:h-full">
          <InternetQualityWidget
            connectivity={data?.connectivity ?? null}
            isLoading={isLoading}
          />
        </motion.div>
        <motion.div variants={itemVariants} className="h-full *:data-[slot=card]:h-full">
          <DeviceInfoWidget />
        </motion.div>
      </motion.div>

      {/* === Row 1 — Signal detail (3 cards): 4G | 5G | Autolock ===
          No section header per user feedback v0.3.2-vn — the cards speak
          for themselves and the heading was visual noise. */}
      <motion.div
        className="grid grid-cols-1 @3xl/main:grid-cols-2 @5xl/main:grid-cols-3 gap-4"
        variants={containerVariants}
        initial="hidden"
        animate="visible"
      >
        <motion.div variants={itemVariants} className="h-full *:data-[slot=card]:h-full">
          <RatPrimaryCard
            title={t("dashboard.fourGPrimary")}
            description={t("dashboard.fourGDescription")}
            carrierComponents={data?.network?.carrier_components ?? null}
            technology="LTE"
            isLoading={isLoading}
          />
        </motion.div>
        <motion.div variants={itemVariants} className="h-full *:data-[slot=card]:h-full">
          <RatPrimaryCard
            title={t("dashboard.fiveGPrimary")}
            description={t("dashboard.fiveGDescription")}
            carrierComponents={data?.network?.carrier_components ?? null}
            technology="NR"
            isLoading={isLoading}
          />
        </motion.div>
        <motion.div variants={itemVariants} className="h-full *:data-[slot=card]:h-full">
          <AutolockCard />
        </motion.div>
      </motion.div>

      {/* === Row 2 — Cellular Information | System Health | Recent Activities === */}
      <motion.div
        className="grid grid-cols-1 @3xl/main:grid-cols-2 @5xl/main:grid-cols-3 gap-4"
        variants={containerVariants}
        initial="hidden"
        animate="visible"
      >
        <motion.div variants={itemVariants} className="h-full *:data-[slot=card]:h-full">
          <CellDataComponent
            network={data?.network ?? null}
            lte={data?.lte ?? null}
            nr={data?.nr ?? null}
            device={data?.device ?? null}
            isLoading={isLoading}
          />
        </motion.div>
        <motion.div variants={itemVariants} className="h-full *:data-[slot=card]:h-full">
          <DeviceMetricsComponent
            deviceData={data?.device ?? null}
            lteData={data?.lte ?? null}
            nrData={data?.nr ?? null}
            isLoading={isLoading}
          />
        </motion.div>
        <motion.div variants={itemVariants} className="h-full *:data-[slot=card]:h-full">
          <RecentActivitiesComponent />
        </motion.div>
      </motion.div>
    </div>
  );
};

export default HomeComponent;
