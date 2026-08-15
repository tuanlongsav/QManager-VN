"use client";

import React, { useEffect, useSyncExternalStore } from "react";
import { usePathname } from "next/navigation";
import { motion } from "motion/react";

import {
  SidebarInset,
  SidebarProvider,
  SidebarTrigger,
} from "@/components/ui/sidebar";

import {
  Breadcrumb,
  BreadcrumbItem,
  BreadcrumbLink,
  BreadcrumbList,
  BreadcrumbPage,
  BreadcrumbSeparator,
} from "@/components/ui/breadcrumb";

import { Separator } from "@/components/ui/separator";
import { Spinner } from "@/components/ui/spinner";
import { AppSidebar } from "@/components/app-sidebar";
import { useBreadcrumbs } from "@/hooks/use-breadcrumbs";
import { SimSwapBanner } from "@/components/monitoring/watchdog/sim-swap-banner";
import { UnsupportedModelBanner } from "@/components/layout/unsupported-model-banner";
import {
  clearAuthRedirectBudget,
  getSessionServerSnapshot,
  getSessionSnapshot,
  isAuthRedirectBudgetExhausted,
  navigateForAuth,
  subscribeToSession,
} from "@/lib/session";
import { useAutoLogout } from "@/hooks/use-auto-logout";
import { useT } from "@/hooks/use-i18n";

/**
 * Owns the auth poller's lifetime by owning its mount.
 *
 * useAutoLogout starts a 10s interval that navigates to /login/ on its own
 * authority. Called from AppLayout's body it would keep running past the point
 * where the gate has already decided this page is leaving — including when the
 * gate deliberately refused to redirect because the budget was spent, at which
 * point the poller simply performs the redirect the budget just vetoed, one
 * tick later. Hooks cannot be called conditionally, so the condition is
 * expressed as a mount: this component only exists in the authenticated tree,
 * and unmounting it is what runs the interval's cleanup.
 */
function SessionPoller() {
  useAutoLogout();
  return null;
}

export function AppLayout({ children }: { children: React.ReactNode }) {
  const breadcrumbs = useBreadcrumbs();
  const pathname = usePathname();
  const { t } = useT();

  // Three states, not a boolean. The cookie is genuinely external, so this is
  // the right hook — but the snapshot has to admit that during hydration the
  // answer is not yet known. See getSessionServerSnapshot for why a `false`
  // server snapshot logs out every user on every load under static export.
  const session = useSyncExternalStore(
    subscribeToSession,
    getSessionSnapshot,
    getSessionServerSnapshot
  );

  useEffect(() => {
    // "unknown" means hydration hasn't handed us the real cookie yet. Doing
    // nothing here is the entire fix: React re-runs this effect with a definite
    // verdict as soon as it re-renders with the client snapshot.
    if (session === "unknown") return;

    if (session === "authenticated") {
      // Terminal: the dashboard renders below and nothing here will navigate
      // away. The user has arrived somewhere they can act, which is the only
      // thing that ends a chain.
      clearAuthRedirectBudget();
      return;
    }

    // "refused" needs no branch here: the anonymous render below asks the budget
    // the same question, and it has already run — React commits the render
    // before it runs passive effects — so the escape link is on screen instead
    // of the hand-off spinner by the time this refusal comes back.
    navigateForAuth("/login/");
  }, [session]);

  // Rendering nothing rather than a spinner: for the overwhelming majority of
  // loads (a logged-in user) this state lasts one commit, and a spinner that
  // appears and vanishes within a frame reads as a flicker, not as feedback.
  if (session === "unknown") {
    return null;
  }

  if (session === "anonymous") {
    // This branch is what an ordinary logged-out visitor looks at, not a rare
    // fault state. React commits the render first and runs passive effects
    // after it, and the effect's `window.location.href =` only *queues* a
    // navigation — the current document stays on screen for the whole time the
    // /login/ request is in flight, which on a busy modem is seconds. So
    // whatever this returns is the real hand-off screen, and it must not accuse
    // an unauthenticated user of anything.
    //
    // A spent budget is the one case where the hand-off is never coming.
    // isAuthRedirectBudgetExhausted tests the same count against the same limit
    // that claimAuthRedirect is about to refuse on, so the render and the effect
    // reach the same verdict without the render having to wait for the effect.
    if (isAuthRedirectBudgetExhausted()) {
      // A link instead of another redirect: it ends the loop, and it still gets
      // the user somewhere useful in one click.
      return (
        <div className="flex min-h-svh flex-col items-center justify-center gap-3 bg-background px-6 text-center">
          <p className="text-sm text-muted-foreground">
            {t("authGate.sessionUnconfirmed")}
          </p>
          <a
            href="/login/"
            className="text-sm font-medium text-primary underline underline-offset-4"
          >
            {t("authGate.goToSignIn")}
          </a>
        </div>
      );
    }

    // Held invisible for the first beat: a healthy hand-off to /login/ finishes
    // well inside the delay, and a spinner that appears and vanishes within a
    // frame reads as a fault rather than as progress. It fades in only once the
    // navigation is slow enough that silence would look like a hung page.
    return (
      <motion.div
        className="flex min-h-svh items-center justify-center bg-background"
        initial={{ opacity: 0 }}
        animate={{ opacity: 1 }}
        transition={{ delay: 0.6, duration: 0.2, ease: "easeOut" }}
      >
        <Spinner className="size-6 text-muted-foreground" />
      </motion.div>
    );
  }

  return (
    <SidebarProvider>
      <SessionPoller />
      <a
        href="#main-content"
        className="sr-only focus:not-sr-only focus:fixed focus:top-4 focus:left-4 focus:z-50 focus:rounded-md focus:bg-background focus:px-4 focus:py-2 focus:text-sm focus:font-medium focus:shadow-lg focus:ring-2 focus:ring-ring"
      >
        Skip to main content
      </a>
      <AppSidebar />
      <SidebarInset>
        <header className="flex h-16 shrink-0 items-center gap-2">
          <div className="flex items-center gap-2 px-4">
            <SidebarTrigger className="-ml-1" />
            <Separator
              orientation="vertical"
              className="mr-2 data-[orientation=vertical]:h-4"
            />
            <Breadcrumb>
              <BreadcrumbList>
                {breadcrumbs.map((breadcrumb, index) => (
                  <React.Fragment key={breadcrumb.href}>
                    {index > 0 && (
                      <BreadcrumbSeparator className="hidden desktop:block" />
                    )}
                    <BreadcrumbItem
                      className={
                        breadcrumb.isCurrentPage ? "" : "hidden desktop:block"
                      }
                    >
                      {breadcrumb.isCurrentPage ? (
                        <BreadcrumbPage>{breadcrumb.label}</BreadcrumbPage>
                      ) : (
                        <BreadcrumbLink href={breadcrumb.href}>
                          {breadcrumb.label}
                        </BreadcrumbLink>
                      )}
                    </BreadcrumbItem>
                  </React.Fragment>
                ))}
              </BreadcrumbList>
            </Breadcrumb>
          </div>
        </header>
        <SimSwapBanner />
        <div className="px-2 lg:px-6">
          <UnsupportedModelBanner />
        </div>
        <motion.div
          id="main-content"
          key={pathname}
          className="px-2 lg:px-6 py-4"
          initial={{ opacity: 0, y: 6 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.2, ease: "easeOut" }}
        >
          {children}
        </motion.div>
      </SidebarInset>
    </SidebarProvider>
  );
}
