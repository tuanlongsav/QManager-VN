import { SignalStatusCard } from "./signal-status-card";
import type { NrStatus } from "@/types/modem-status";
import {
  RSRP_THRESHOLDS,
  RSRQ_THRESHOLDS,
  SINR_THRESHOLDS,
} from "@/types/modem-status";

interface NrStatusComponentProps {
  data: NrStatus | null;
  isLoading: boolean;
}

const NrStatusComponent = ({ data, isLoading }: NrStatusComponentProps) => {
  const fmt = (value: number | null | undefined, unit: string) => {
    if (value === null || value === undefined) return "-";
    return `${value} ${unit}`;
  };

  // Layout intentionally mirrors lte-status.tsx — identity (Band/Channel/PCI)
  // first, signal-quality block (RSRP / RSRQ / SINR) second. The 7th row is
  // RAT-specific (SCS on NR, RSSI on LTE) so both cards have the same row
  // count + height. Quectel's NR AT response doesn't include RSSI.
  const rows = [
    { label: "Band", value: data?.band || "-" },
    { label: "ARFCN", value: data?.arfcn?.toString() ?? "-" },
    { label: "PCI", value: data?.pci?.toString() ?? "-" },
    {
      label: "RSRP",
      value: fmt(data?.rsrp, "dBm"),
      rawValue: data?.rsrp,
      thresholds: RSRP_THRESHOLDS,
    },
    {
      label: "RSRQ",
      value: fmt(data?.rsrq, "dB"),
      rawValue: data?.rsrq,
      thresholds: RSRQ_THRESHOLDS,
    },
    {
      label: "SINR",
      value: fmt(data?.sinr, "dB"),
      rawValue: data?.sinr,
      thresholds: SINR_THRESHOLDS,
    },
    { label: "SCS", value: fmt(data?.scs, "kHz") },
  ];

  return (
    <SignalStatusCard
      title="5G Primary Status"
      state={data?.state ?? "unknown"}
      rsrp={data?.rsrp ?? null}
      rows={rows}
      isLoading={isLoading}
    />
  );
};

export default NrStatusComponent;
