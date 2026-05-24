"use client";

import NeighbourCellScanner from "./neighbour-scanner";
import { useT } from "@/hooks/use-i18n";

const NeighbourcellComponent = () => {
  const { t } = useT();
  return (
    <div className="@container/main mx-auto p-2">
      <div className="mb-6">
        <h1 className="text-3xl font-bold mb-2">{t("cellScanner.neighbourTitle")}</h1>
        <p className="text-muted-foreground">{t("cellScanner.neighbourDescription")}</p>
      </div>
      <NeighbourCellScanner />
    </div>
  );
};

export default NeighbourcellComponent;
