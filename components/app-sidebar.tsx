"use client";

import * as React from "react";
import {
  LifeBuoy,
  PieChart,
  Settings2,
  HomeIcon,
  LucideSignal,
  MessageCircleIcon,
  DogIcon,
  RouterIcon,
  User2Icon,
  HeartIcon,
  ScanIcon,
  SettingsIcon,
  DownloadIcon,
  EthernetPort,
} from "lucide-react";

import QManagerLogo from "@/public/qmanager-logo.svg";

import { NavMain } from "@/components/nav-main";
import { NavLocalNetwork } from "@/components/nav-localNetwork";
import { NavSecondary } from "@/components/nav-secondary";
import { NavUser } from "@/components/nav-user";
import { NavMonitoring } from "@/components/nav-monitoring";
import { NavCellular } from "@/components/nav-cellular";
import { NavSystem } from "@/components/nav-system";
import DonateDialog from "@/components/donate-dialog";
import {
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarHeader,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
} from "@/components/ui/sidebar";
import Image from "next/image";
import Link from "next/link";

import { LanguageToggle } from "@/components/language-toggle";
import { useT } from "@/hooks/use-i18n";

// Static, untranslated user metadata. Title strings are translated below
// inside `buildData()` so they update reactively when the user toggles
// the language.
const staticData = {
  user: {
    name: "Admin",
    avatar: QManagerLogo.src,
  },
};

// Build the menu tree against the current translation function. Called
// inside the component so it re-runs on lang change.
function buildData(t: (k: string) => string) {
  return {
    user: staticData.user,
    navMain: [
      {
        title: t("sidebar.home"),
        url: "/dashboard",
        icon: HomeIcon,
        isActive: true,
      },
    ],
    system: [
      {
        title: t("sidebar.systemSettings"),
        url: "/system-settings",
        icon: SettingsIcon,
        items: [
          { title: t("sidebar.logs"), url: "/system-settings/logs" },
          {
            title: t("sidebar.connectionQuality"),
            url: "/system-settings/connection-quality",
          },
        ],
      },
      {
        title: t("sidebar.softwareUpdate"),
        url: "/system-settings/software-update",
        icon: DownloadIcon,
      },
    ],
    navSecondary: [
      { title: t("sidebar.aboutDevice"), url: "/about-device", icon: RouterIcon },
      { title: t("sidebar.support"), url: "/support", icon: LifeBuoy },
      // Donate slot retains the English key as the matcher in the onClick
      // wiring below (see line further down). The visible label is translated.
      { title: t("sidebar.donate"), url: "#", icon: HeartIcon },
    ],
    cellular: [
      {
        title: t("sidebar.smsCenter"),
        url: "/cellular/sms",
        icon: MessageCircleIcon,
      },
      {
        title: t("sidebar.customProfiles"),
        url: "/cellular/custom-profiles",
        icon: User2Icon,
        items: [
          {
            title: t("sidebar.connectionScenarios"),
            url: "/cellular/custom-profiles/connection-scenarios",
          },
        ],
      },
      {
        title: t("sidebar.bandLocking"),
        url: "/cellular/cell-locking",
        icon: LucideSignal,
        items: [
          {
            title: t("sidebar.towerLocking"),
            url: "/cellular/cell-locking/tower-locking",
          },
          {
            title: t("sidebar.frequencyLocking"),
            url: "/cellular/cell-locking/frequency-locking",
          },
        ],
      },
      {
        title: t("sidebar.cellScanner"),
        url: "/cellular/cell-scanner",
        icon: ScanIcon,
        items: [
          {
            title: t("sidebar.neighbouringCells"),
            url: "/cellular/cell-scanner/neighbourcell-scanner",
          },
          {
            title: t("sidebar.frequencyCalculator"),
            url: "/cellular/cell-scanner/frequency-calculator",
          },
        ],
      },
      {
        title: t("sidebar.settings"),
        url: "/cellular/settings",
        icon: Settings2,
        items: [
          {
            title: t("sidebar.apnManagement"),
            url: "/cellular/settings/apn-management",
          },
          {
            title: t("sidebar.networkPriority"),
            url: "/cellular/settings/network-priority",
          },
          {
            title: t("sidebar.imeiSettings"),
            url: "/cellular/settings/imei-settings",
          },
          {
            title: t("sidebar.fplmnSettings"),
            url: "/cellular/settings/fplmn-settings",
          },
        ],
      },
    ],
    localNetwork: [
      {
        title: t("sidebar.ethernetStatus"),
        url: "/local-network/ethernet",
        icon: EthernetPort,
      },
      {
        title: t("sidebar.localNetworkSettings"),
        url: "/local-network/ip-passthrough",
        icon: Settings2,
        items: [
          {
            title: t("sidebar.ttlMtuSettings"),
            url: "/local-network/ttl-settings",
          },
          { title: t("sidebar.customDns"), url: "/local-network/custom-dns" },
        ],
      },
    ],
    monitoring: [
      {
        title: t("sidebar.networkEvents"),
        url: "/monitoring",
        icon: PieChart,
        items: [
          { title: t("sidebar.latencyMonitor"), url: "/monitoring/latency" },
          { title: t("sidebar.smsAlerts"), url: "/monitoring/sms-alerts" },
        ],
      },
      { title: t("sidebar.watchdog"), url: "/monitoring/watchdog", icon: DogIcon },
    ],
  };
}

export function AppSidebar({ ...props }: React.ComponentProps<typeof Sidebar>) {
  const [donateOpen, setDonateOpen] = React.useState(false);
  const { t } = useT();
  const data = React.useMemo(() => buildData(t), [t]);

  // The donate slot is matched by its translated label OR the fixed url "#".
  // Using url is more robust across languages than label equality.
  const navSecondaryItems = data.navSecondary.map((item) =>
    item.url === "#"
      ? { ...item, onClick: () => setDonateOpen(true) }
      : item,
  );

  return (
    <Sidebar variant="inset" {...props}>
      <SidebarHeader>
        <SidebarMenu>
          <SidebarMenuItem>
            <div className="flex items-center gap-1">
              <SidebarMenuButton size="lg" asChild className="flex-1">
                <Link href="/dashboard">
                  <div className="flex aspect-square size-8 items-center justify-center rounded-lg">
                    <Image
                      src={QManagerLogo}
                      alt="QManager Logo"
                      className="size-full"
                      priority
                    />
                  </div>
                  <div className="grid flex-1 text-left text-sm leading-tight">
                    <span className="truncate font-medium">QManager</span>
                    <span className="truncate text-xs">Admin</span>
                  </div>
                </Link>
              </SidebarMenuButton>
              {/* Language toggle (QManager-VN F.3.B) — flag dropdown switching
                  English / Vietnamese. Placed next to the QManager Admin
                  header per user request. */}
              <LanguageToggle compact />
            </div>
          </SidebarMenuItem>
        </SidebarMenu>
      </SidebarHeader>
      <SidebarContent>
        <NavMain items={data.navMain} />
        <NavCellular cellular={data.cellular} />
        <NavLocalNetwork localNetwork={data.localNetwork} />
        <NavMonitoring monitoring={data.monitoring} />
        <NavSystem system={data.system} />
        <NavSecondary items={navSecondaryItems} className="mt-auto" />
      </SidebarContent>
      <SidebarFooter>
        <NavUser user={data.user} />
      </SidebarFooter>
      <DonateDialog open={donateOpen} onOpenChange={setDonateOpen} />
    </Sidebar>
  );
}
