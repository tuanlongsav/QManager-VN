"use client";

import { useEffect, useRef, useState } from "react";
import {
  ChevronsUpDown,
  KeyRound,
  Loader2,
  LogOut,
  Power,
  RefreshCw,
  Camera,
  Pencil,
} from "lucide-react";
import { toast } from "sonner";
import { logout } from "@/hooks/use-auth";
import { authFetch } from "@/lib/auth-fetch";
import { fileToAvatarDataUrl } from "@/lib/avatar-image";
import {
  readStorageValueOrNull,
  writeStorageValue,
} from "@/lib/browser-storage";
import { navigateForAuth, prepareForReboot } from "@/lib/session";
import { useT } from "@/hooks/use-i18n";
import type { SaveSettingsResponse } from "@/types/system-settings";

import {
  Avatar,
  AvatarFallback,
  AvatarImage,
} from "@/components/ui/avatar";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuGroup,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import {
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
  useSidebar,
} from "@/components/ui/sidebar";
import { ChangePasswordDialog } from "@/components/auth/change-password-dialog";

/** Where the user's uploaded avatar is cached, as a data: URL. */
const AVATAR_STORAGE_KEY = "qm_display_avatar";

export function NavUser({
  user,
}: {
  user: {
    name: string;
    avatar: string;
  };
}) {
  const { isMobile } = useSidebar();
  const { t } = useT();

  // --- Display name from device hostname ---
  const [displayName, setDisplayName] = useState<string>(user.name);
  // Read through lib/browser-storage, never `localStorage` directly. This runs
  // inside a useState INITIALIZER, i.e. during render, and NavUser sits in the
  // sidebar of every authenticated page — so a SecurityError thrown here (a
  // storage-blocked WebView, Safari with cookies off) does not degrade the
  // avatar, it blanks the entire app. `typeof window` was never the right guard:
  // in those browsers `window` exists and it is the `localStorage` property
  // lookup itself that throws.
  //
  // ...OrNull is the deliberate collapse: "no stored avatar" and "no storage at
  // all" both mean the same thing to a decorative picture — show the default.
  const [avatarSrc, setAvatarSrc] = useState<string>(
    () => readStorageValueOrNull("local", AVATAR_STORAGE_KEY) || user.avatar
  );

  // Fetch hostname from system settings on mount
  useEffect(() => {
    authFetch("/cgi-bin/quecmanager/system/settings.sh")
      .then((r) => r.json())
      .then((json) => {
        if (json.success && json.settings?.hostname) {
          setDisplayName(json.settings.hostname);
        }
      })
      .catch(() => {});
  }, []);

  // --- Dialog state ---
  const [passwordDialogOpen, setPasswordDialogOpen] = useState(false);
  const [nameDialogOpen, setNameDialogOpen] = useState(false);
  const [rebootDialogOpen, setRebootDialogOpen] = useState(false);
  const [reconnectDialogOpen, setReconnectDialogOpen] = useState(false);
  const [rebooting, setRebooting] = useState(false);
  const [reconnecting, setReconnecting] = useState(false);

  // --- Name edit state ---
  const [nameInput, setNameInput] = useState(displayName);

  // --- Avatar upload ---
  const fileInputRef = useRef<HTMLInputElement>(null);

  const handleAvatarClick = () => {
    fileInputRef.current?.click();
  };

  const handleFileChange = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;
    if (!file.type.startsWith("image/")) {
      toast.error(t("navUser.toastImageOnly"));
      return;
    }
    const base64 = await fileToAvatarDataUrl(file);
    if (!base64) {
      toast.error(t("navUser.toastImageTooLarge"));
      return;
    }
    // The picture is applied to this session either way — that part cannot fail.
    // Persisting it can: a data: URL of a photo is easily a megabyte, which is
    // what tips an origin over its localStorage quota (setItem then throws
    // QuotaExceededError), and a storage-blocked document rejects the write
    // outright. Say so rather than reporting an unqualified success the user will
    // discover was untrue on their next page load.
    const persisted = writeStorageValue("local", AVATAR_STORAGE_KEY, base64);
    setAvatarSrc(base64);
    if (persisted) {
      toast.success(t("navUser.toastPhotoUpdated"));
    } else {
      toast.warning(t("navUser.toastPhotoNotSaved"));
    }
    e.target.value = "";
  };

  // --- Name save (updates device hostname) ---
  const [savingName, setSavingName] = useState(false);

  const handleNameSave = async () => {
    const name = nameInput.trim();
    if (!name) return;
    setSavingName(true);
    try {
      const resp = await authFetch("/cgi-bin/quecmanager/system/settings.sh", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ action: "save_settings", hostname: name }),
      });
      const json: SaveSettingsResponse = await resp.json();
      if (!json.success) {
        toast.error(t("navUser.toastNameFailed"));
        return;
      }
      setDisplayName(name);
      setNameDialogOpen(false);
      // The display name is what this dialog edits, and it is saved either way.
      // The system hostname derived from it can still fail to apply — most
      // likely on a device that has not yet taken the update carrying the root
      // helper — so warn about that half rather than reporting the rename as
      // failed, which would be untrue.
      if (json.hostname_applied === false) {
        toast.warning(t("navUser.toastNameSystemPending"));
      } else {
        toast.success(t("navUser.toastNameUpdated"));
      }
    } catch {
      toast.error(t("navUser.toastNameFailed"));
    } finally {
      setSavingName(false);
    }
  };

  // --- Reboot (optimistic) ---
  // Navigate to the countdown page FIRST, then fire the reboot request.
  // This ensures the /reboot/ page loads from cache/memory before the
  // device goes offline. The backend delays reboot by 1s after responding.
  const handleReboot = async (e: React.MouseEvent) => {
    e.preventDefault();
    setRebooting(true);

    // Prepare session state for the countdown page. The return value is NOT
    // decoration: it says whether the "a reboot really was requested" marker
    // reached sessionStorage, and /reboot/ refuses to show the countdown to a
    // visitor without one. Ignoring it (as this did) sends a user with unusable
    // storage to a page that immediately bounces them somewhere else.
    const countdownArmed = prepareForReboot();

    // Fire-and-forget: keepalive ensures the request survives page navigation.
    // This happens regardless of the marker — the user asked for a reboot, and
    // failing to write a UI breadcrumb is no reason to withhold it.
    fetch("/cgi-bin/quecmanager/system/reboot.sh", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ action: "reboot" }),
      keepalive: true,
    }).catch(() => {});

    // Leave through the shared guard rather than assigning window.location
    // directly. WHY it matters even though this is a plain user click: the
    // assignment only *queues* a document load, it does not stop this page. The
    // dashboard's pollers keep running for as long as the new document takes to
    // arrive, and on a device that is in the act of rebooting they are all about
    // to fail at once. A 401 landing in authFetch during that window cancels the
    // /reboot/ load and starts a /login/ one instead — the reproduced bug. The
    // latch inside navigateForAuth is set before the assignment, so those 401
    // handlers see "already leaving" and stand down.
    //
    // countsAsBounce:false because /reboot/ is the textbook uncounted edge: the
    // device is going down, the countdown page never hands on to a gate, and
    // spending budget here would leave the loop breaker poorer for the /login/
    // hop the user genuinely needs when the box comes back.
    //
    // Without the marker, /reboot/ may treat this as a direct URL visit and
    // bounce onward anyway, so go straight to /login/ — which is what
    // lib/session.ts's prepareForReboot contract prescribes for a caller that
    // reads the result. The user loses the countdown animation and waits on the
    // login form instead; the reboot is already on its way, so there is nothing
    // to undo, only a better place to wait. That hop DOES count as a bounce:
    // /login/ is a real auth gate that can hand on to /setup/ or /dashboard/.
    //
    // "may", not "will": a `false` here has two causes that /reboot/ can tell
    // apart even though we cannot. A rejected write on a working store leaves the
    // marker genuinely absent and /reboot/ does bounce; a store this document
    // cannot touch at all leaves /reboot/ unable to read the marker either, and
    // it fails open and shows the countdown. Taking the /login/ branch for both
    // costs the second group an animation and nothing else, which is the cheaper
    // side to be wrong on than duplicating /reboot/'s fail-open policy here and
    // having the two drift apart later.
    const outcome = countdownArmed
      ? navigateForAuth("/reboot/", { countsAsBounce: false })
      : navigateForAuth("/login/");

    // "started" and "suppressed" both mean the browser is leaving and there is
    // nothing left for this component to do. "refused" (only reachable on the
    // budget-counted /login/ fallback) means no navigation will ever happen — so
    // stop here and leave the dialog on its terminal "Reboot command sent" text,
    // which is still true. Re-enabling the button would only invite a second
    // reboot of a device that is already going down.
    if (outcome === "refused") {
      console.error(
        "[nav-user] Reboot requested but the redirect budget refused the " +
          "hand-off to /login/. The device is still rebooting; this page will " +
          "stop responding shortly."
      );
    }
  };

  const handleReconnect = async (e: React.MouseEvent) => {
    e.preventDefault();
    setReconnecting(true);
    try {
      const resp = await authFetch("/cgi-bin/quecmanager/system/reboot.sh", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ action: "reconnect" }),
      });
      const data = await resp.json();
      if (data.success) {
        toast.success(t("navUser.toastReconnectStarted"));
      } else {
        toast.error(t("navUser.toastReconnectFailed"));
      }
    } catch {
      toast.error(t("navUser.toastReconnectError"));
    } finally {
      setReconnecting(false);
      setReconnectDialogOpen(false);
    }
  };

  const initials =
    displayName
      .split(/[-_ ]+/)
      .slice(0, 2)
      .map((w) => w[0]?.toUpperCase() ?? "")
      .join("") || "QM";

  return (
    <>
      {/* Hidden file input for avatar upload */}
      <input
        ref={fileInputRef}
        type="file"
        accept="image/*"
        className="hidden"
        onChange={handleFileChange}
      />

      <SidebarMenu>
        <SidebarMenuItem>
          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <SidebarMenuButton
                size="lg"
                className="data-[state=open]:bg-sidebar-accent data-[state=open]:text-sidebar-accent-foreground"
              >
                <Avatar className="h-8 w-8 rounded-lg">
                  <AvatarImage src={avatarSrc} alt={displayName} />
                  <AvatarFallback className="rounded-lg">
                    {initials}
                  </AvatarFallback>
                </Avatar>
                <div className="grid flex-1 text-left text-sm leading-tight">
                  <span className="truncate font-medium">{displayName}</span>
                </div>
                <ChevronsUpDown className="ml-auto size-4" />
              </SidebarMenuButton>
            </DropdownMenuTrigger>
            <DropdownMenuContent
              className="w-(--radix-dropdown-menu-trigger-width) min-w-56 rounded-lg"
              side={isMobile ? "bottom" : "right"}
              align="end"
              sideOffset={4}
            >
              <DropdownMenuLabel className="p-0 font-normal">
                <div className="flex items-center gap-2 px-1 py-1.5 text-left text-sm">
                  {/* Clickable avatar with camera overlay */}
                  <button
                    type="button"
                    onClick={handleAvatarClick}
                    className="relative group shrink-0 rounded-lg focus:outline-none focus-visible:ring-2 focus-visible:ring-ring"
                    aria-label={t("navUser.changeProfilePhoto")}
                  >
                    <Avatar className="h-8 w-8 rounded-lg">
                      <AvatarImage src={avatarSrc} alt={displayName} />
                      <AvatarFallback className="rounded-lg">
                        {initials}
                      </AvatarFallback>
                    </Avatar>
                    <div className="absolute inset-0 rounded-lg bg-black/50 flex items-center justify-center opacity-0 group-hover:opacity-100 transition-opacity">
                      <Camera className="size-3.5 text-white" />
                    </div>
                  </button>
                  <div className="grid flex-1 text-left text-sm leading-tight">
                    <span className="truncate font-medium">{displayName}</span>
                  </div>
                </div>
              </DropdownMenuLabel>
              <DropdownMenuSeparator />
              <DropdownMenuGroup>
                <DropdownMenuItem
                  onClick={() => {
                    setNameInput(displayName);
                    setNameDialogOpen(true);
                  }}
                >
                  <Pencil />
                  {t("navUser.changeDisplayName")}
                </DropdownMenuItem>
                <DropdownMenuItem
                  onClick={() => setPasswordDialogOpen(true)}
                >
                  <KeyRound />
                  {t("navUser.changePassword")}
                </DropdownMenuItem>
              </DropdownMenuGroup>
              <DropdownMenuSeparator />
              <DropdownMenuItem
                onClick={() => setReconnectDialogOpen(true)}
              >
                <RefreshCw />
                {t("navUser.reconnectNetwork")}
              </DropdownMenuItem>
              <DropdownMenuItem
                variant="destructive"
                onClick={() => setRebootDialogOpen(true)}
              >
                <Power />
                {t("navUser.rebootDevice")}
              </DropdownMenuItem>
              <DropdownMenuItem onClick={() => logout()}>
                <LogOut />
                {t("navUser.logOut")}
              </DropdownMenuItem>
            </DropdownMenuContent>
          </DropdownMenu>
        </SidebarMenuItem>
      </SidebarMenu>

      {/* Change Display Name dialog */}
      <Dialog
        open={nameDialogOpen}
        onOpenChange={(open) => {
          setNameDialogOpen(open);
          if (!open) setNameInput(displayName);
        }}
      >
        <DialogContent className="sm:max-w-sm">
          <DialogHeader>
            <DialogTitle>{t("navUser.changeDisplayName")}</DialogTitle>
          </DialogHeader>
          <div className="py-2">
            <Input
              value={nameInput}
              onChange={(e) => setNameInput(e.target.value)}
              placeholder={t("navUser.namePlaceholder")}
              autoFocus
              onKeyDown={(e) => {
                if (e.key === "Enter") handleNameSave();
              }}
            />
          </div>
          <DialogFooter>
            <Button
              variant="outline"
              onClick={() => setNameDialogOpen(false)}
            >
              {t("common.cancel")}
            </Button>
            <Button
              onClick={handleNameSave}
              disabled={!nameInput.trim() || nameInput.trim() === displayName || savingName}
            >
              {savingName ? (
                <>
                  <Loader2 className="size-4 animate-spin" />
                  {t("navUser.saving")}
                </>
              ) : (
                t("common.save")
              )}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <ChangePasswordDialog
        open={passwordDialogOpen}
        onOpenChange={setPasswordDialogOpen}
      />

      <AlertDialog open={reconnectDialogOpen} onOpenChange={(open) => {
        if (!reconnecting) setReconnectDialogOpen(open);
      }}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{t("navUser.reconnectNetwork")}</AlertDialogTitle>
            <AlertDialogDescription>
              {t("navUser.reconnectDescription")}
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel disabled={reconnecting}>
              {t("common.cancel")}
            </AlertDialogCancel>
            <AlertDialogAction
              disabled={reconnecting}
              onClick={handleReconnect}
            >
              {reconnecting ? (
                <>
                  <Loader2 className="size-4 animate-spin" />
                  {t("navUser.reconnecting")}
                </>
              ) : (
                t("navUser.reconnect")
              )}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>

      <AlertDialog open={rebootDialogOpen} onOpenChange={(open) => {
        if (!rebooting) setRebootDialogOpen(open);
      }}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{t("navUser.rebootDevice")}</AlertDialogTitle>
            <AlertDialogDescription aria-live="polite">
              {rebooting
                ? t("navUser.rebootSent")
                : t("navUser.rebootDescription")}
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel disabled={rebooting}>
              {t("navUser.notNow")}
            </AlertDialogCancel>
            <AlertDialogAction
              variant="destructive"
              disabled={rebooting}
              onClick={handleReboot}
            >
              {rebooting ? (
                <>
                  <Loader2 className="size-4 animate-spin" />
                  {t("navUser.rebooting")}
                </>
              ) : (
                t("navUser.rebootNow")
              )}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </>
  );
}
