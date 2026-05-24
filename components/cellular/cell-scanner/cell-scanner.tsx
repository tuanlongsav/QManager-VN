"use client";

import FullScannerComponent from "./scanner";
import { useT } from "@/hooks/use-i18n";

const CellScannerComponent = () => {
  const { t } = useT();
  return (
    <div className="@container/main mx-auto p-2">
      <div className="mb-6">
        <h1 className="text-3xl font-bold mb-2">{t("cellScanner.title")}</h1>
        <p className="text-muted-foreground">{t("cellScanner.description")}</p>
      </div>
      <FullScannerComponent />
    </div>
  );
};

export default CellScannerComponent;
