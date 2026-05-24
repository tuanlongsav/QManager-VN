"use client";

import React from "react";
import { motion, type Variants } from "motion/react";
import { useModemStatus } from "@/hooks/use-modem-status";
import { useAboutDevice } from "@/hooks/use-about-device";
import { NetworkStatusCompact } from "./network-status-compact";
import { TemperatureWidget } from "./temperature-widget";
import { SmsReceivedWidget } from "./sms-received-widget";
import { InternetQualityWidget } from "./internet-quality-widget";
import { AutolockCard } from "@/components/cellular/tower-locking/autolock-card";
import DeviceStatus from "./device-status";
import LTEStatusComponent from "./lte-status";
import NrStatusComponent from "./nr-status";
import RecentActivitiesComponent from "./recent-activities";
import DeviceMetricsComponent from "./device-metrics";

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

  // Tie poll cadence to the ping daemon's write interval (Connection Sensitivity).
  const daemonIntervalSec = data?.connectivity?.history_interval_sec;
  React.useEffect(() => {
    if (!daemonIntervalSec || daemonIntervalSec <= 0) return;
    const next = daemonIntervalSec * 1000 + POLL_BUFFER_MS;
    setPollInterval((prev) => (prev === next ? prev : next));
  }, [daemonIntervalSec]);

  // isStale reserved for future top-row indicator
  void isStale;

  return (
    <div className="grid grid-cols-1 gap-6 px-4 lg:px-6" aria-live="polite" aria-atomic="false">
      {error && !isLoading && (
        <div role="alert" className="rounded-lg bg-destructive/10 px-4 py-3 text-sm text-destructive">
          Unable to reach the modem. Data shown may be outdated.
        </div>
      )}

      {/* === Top widget row — 4 same-size tiles (QManager-VN F.1) === */}
      <motion.div
        className="grid grid-cols-1 @md/main:grid-cols-2 @4xl/main:grid-cols-4 gap-4"
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
      </motion.div>

      {/* === Signal Status section (QManager-VN F.2.D) ===
          One labeled group containing 4 sub-cards in a 2×2 grid:
          4G Primary Status · 5G Primary Status · Recent Activities · Signal Quality Monitor.
          Replaces the previous full-width LTE/NR/SCC + Live Latency + Signal History rows
          with a single coherent section the user can scan at a glance. */}
      <section aria-labelledby="signal-status-heading" className="space-y-3">
        <div>
          <h2 id="signal-status-heading" className="text-xl font-bold">
            Signal Status
          </h2>
          <p className="text-sm text-muted-foreground">
            Trạng thái tín hiệu 4G/5G hiện tại, hoạt động gần đây và đánh giá chất lượng.
          </p>
        </div>
        <motion.div
          className="grid grid-cols-1 @3xl/main:grid-cols-2 gap-4"
          variants={containerVariants}
          initial="hidden"
          animate="visible"
        >
          <motion.div variants={itemVariants} className="h-full *:data-[slot=card]:h-full">
            <LTEStatusComponent data={data?.lte ?? null} isLoading={isLoading} />
          </motion.div>
          <motion.div variants={itemVariants} className="h-full *:data-[slot=card]:h-full">
            <NrStatusComponent data={data?.nr ?? null} isLoading={isLoading} />
          </motion.div>
          <motion.div variants={itemVariants} className="h-full *:data-[slot=card]:h-full">
            <RecentActivitiesComponent />
          </motion.div>
          <motion.div variants={itemVariants} className="h-full *:data-[slot=card]:h-full">
            {/* Auto cell-lock — moved here from Cellular → Band Locking page
                in F.2.J. Per-row quality tiers in 4G/5G cards above already
                give the user a signal-quality view, so a dedicated quality
                monitor widget became redundant. The auto-lock daemon belongs
                here because it acts on signal-quality changes. */}
            <AutolockCard />
          </motion.div>
        </motion.div>
      </section>

      {/* === System Health + Device Information (balanced 2-col, F.2.E + F.2.F) === */}
      <motion.div
        className="grid grid-cols-1 @3xl/main:grid-cols-2 gap-4"
        variants={containerVariants}
        initial="hidden"
        animate="visible"
      >
        <motion.div variants={itemVariants} className="h-full *:data-[slot=card]:h-full">
          <DeviceMetricsComponent
            deviceData={data?.device ?? null}
            lteData={data?.lte ?? null}
            nrData={data?.nr ?? null}
            isLoading={isLoading}
          />
        </motion.div>
        <motion.div variants={itemVariants} className="h-full *:data-[slot=card]:h-full">
          <DeviceStatus
            data={data?.device ?? null}
            isLoading={isLoading}
            lanGateway={aboutDevice?.network.lan_gateway}
          />
        </motion.div>
      </motion.div>
    </div>
  );
};

export default HomeComponent;
