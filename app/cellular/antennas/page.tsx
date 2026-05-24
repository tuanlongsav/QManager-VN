"use client";

import { useState, useEffect, Suspense } from "react";
import { useSearchParams, useRouter, usePathname } from "next/navigation";

import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { Skeleton } from "@/components/ui/skeleton";
import AntennaStatistics from "@/components/cellular/antenna-statistics/antenna-statistics";
import AntennaAlignmentComponent from "@/components/cellular/antenna-alignment/antenna-alignment";

// =============================================================================
// QManager-VN consolidated Antennas page (Phase E.3)
// =============================================================================
// Combines /cellular/antenna-statistics and /cellular/antenna-alignment into
// one tabbed page. Old routes still resolve for backward compatibility (any
// existing bookmarks or links keep working) but the sidebar entry points here.
//
// The active tab is mirrored to ?tab=stats|alignment so a deep link picks the
// right tab. Default: "stats".
// =============================================================================

type AntennaTab = "stats" | "alignment";

const VALID_TABS: AntennaTab[] = ["stats", "alignment"];

function AntennasInner() {
  const searchParams = useSearchParams();
  const router = useRouter();
  const pathname = usePathname();
  const [tab, setTab] = useState<AntennaTab>("stats");

  useEffect(() => {
    const t = searchParams.get("tab");
    if (t && VALID_TABS.includes(t as AntennaTab)) {
      setTab(t as AntennaTab);
    }
  }, [searchParams]);

  const handleTabChange = (next: string) => {
    const validTab = (VALID_TABS.includes(next as AntennaTab)
      ? next
      : "stats") as AntennaTab;
    setTab(validTab);
    const params = new URLSearchParams(searchParams.toString());
    params.set("tab", validTab);
    router.replace(`${pathname}?${params.toString()}`, { scroll: false });
  };

  return (
    <Tabs value={tab} onValueChange={handleTabChange}>
      <TabsList>
        <TabsTrigger value="stats">Statistics</TabsTrigger>
        <TabsTrigger value="alignment">Alignment</TabsTrigger>
      </TabsList>
      <TabsContent value="stats" className="mt-4">
        <AntennaStatistics />
      </TabsContent>
      <TabsContent value="alignment" className="mt-4">
        <AntennaAlignmentComponent />
      </TabsContent>
    </Tabs>
  );
}

const AntennasPage = () => {
  return (
    <div className="@container/main mx-auto p-2">
      {/* No parent h1 — each tab's component renders its own title block
          ("Antenna Statistics" / "Antenna Alignment"). Keeping their headers
          intact means the direct deep-link routes still look correct, and
          the tab label tells the user which view they're on. */}
      <Suspense
        fallback={
          <div className="space-y-4">
            <Skeleton className="h-10 w-64" />
            <Skeleton className="h-96 w-full" />
          </div>
        }
      >
        <AntennasInner />
      </Suspense>
    </div>
  );
};

export default AntennasPage;
