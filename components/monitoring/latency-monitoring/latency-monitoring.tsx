"use client";

import dynamic from "next/dynamic";
import { useLatencyMonitoring } from "./use-latency-monitoring";
import PingEntriesCard from "./ping-entries-card";
import { Card, CardContent, CardHeader } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";

// recharts (~150 KB) lives entirely inside LatencyMonitoringCard. Loading it
// with next/dynamic + ssr:false keeps it out of the initial bundle the modem
// has to parse — it only downloads when this page is actually opened.
const LatencyMonitoringCard = dynamic(() => import("./latency-monitoring-card"), {
  ssr: false,
  loading: () => (
    <Card>
      <CardHeader className="border-b">
        <Skeleton className="h-5 w-48" />
        <Skeleton className="h-4 w-64" />
      </CardHeader>
      <CardContent className="pt-6">
        <Skeleton className="h-[250px] w-full" />
      </CardContent>
    </Card>
  ),
});

const LatencyMonitoringComponent = () => {
  const { viewMode, setViewMode, chartData, total, tableData } =
    useLatencyMonitoring();

  return (
    <div className="@container/main mx-auto p-2">
      <div className="mb-6">
        <h1 className="text-3xl font-bold mb-2">Latency Monitoring</h1>
        <p className="text-muted-foreground">
          Monitor and analyze latency and packet loss to identify potential
          issues and optimize performance.
        </p>
      </div>
      <div className="grid grid-cols-1 @3xl/main:grid-cols-2 grid-flow-row gap-4">
        <LatencyMonitoringCard
          viewMode={viewMode}
          setViewMode={setViewMode}
          chartData={chartData}
          total={total}
        />
        <PingEntriesCard
          entries={tableData.entries}
          emptyMessage={tableData.emptyMessage}
          isRealtime={tableData.isRealtime}
        />
      </div>
    </div>
  );
};

export default LatencyMonitoringComponent;
