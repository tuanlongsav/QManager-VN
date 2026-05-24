"use client";

import { useAboutDevice } from "@/hooks/use-about-device";
import { useModemStatus } from "@/hooks/use-modem-status";
import DeviceInformationCard from "./device-information-card";
import AboutQManagerCard from "./about-qmanager-card";
import { HardwareBadge } from "./hardware-badge";
import { TemperatureWidget } from "@/components/dashboard/temperature-widget";

const AboutDeviceComponent = () => {
  const { data, isLoading, error, refresh } = useAboutDevice();
  // Modem temperature is a separate poll source from about-device (which only
  // returns identity/network metadata). Pull it via the same hook the
  // dashboard uses so the °C reading stays consistent across pages.
  const { data: modemData, isLoading: isModemLoading } = useModemStatus();

  return (
    <div className="@container/main mx-auto p-2">
      <div className="mb-6">
        <div className="flex flex-wrap items-center gap-3 mb-2">
          <h1 className="text-3xl font-bold">About Device</h1>
          <HardwareBadge />
        </div>
        <p className="text-muted-foreground">
          Device identity, network addresses, and system information.
        </p>
      </div>
      <div className="grid grid-cols-1 @3xl/main:grid-cols-2 @5xl/main:grid-cols-3 grid-flow-row gap-4">
        <TemperatureWidget
          temperature={modemData?.device?.temperature ?? null}
          isLoading={isModemLoading}
        />
        <DeviceInformationCard
          data={data}
          isLoading={isLoading}
          error={error}
          onRetry={refresh}
        />
        <AboutQManagerCard data={data} isLoading={isLoading} />
      </div>
    </div>
  );
};

export default AboutDeviceComponent;
