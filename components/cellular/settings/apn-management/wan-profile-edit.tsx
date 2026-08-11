"use client";

import { useState, type FormEvent } from "react";
import { MNO_PRESETS, suggestPresetFromImsi, type MnoPreset } from "@/constants/mno-presets";
import { useModemStatus } from "@/hooks/use-modem-status";
import { toast } from "sonner";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import {
  Field,
  FieldGroup,
  FieldLabel,
  FieldSet,
  FieldError,
} from "@/components/ui/field";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { Switch } from "@/components/ui/switch";
import { Skeleton } from "@/components/ui/skeleton";
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { SaveButton, useSaveFlash } from "@/components/ui/save-button";
import {
  Tooltip,
  TooltipTrigger,
  TooltipContent,
} from "@/components/ui/tooltip";
import {
  EyeIcon,
  EyeOffIcon,
  InfoIcon,
} from "lucide-react";
import { TbInfoCircleFilled } from "react-icons/tb";

import type { WanProfile, WanProfileSaveRequest } from "@/types/wan-profiles";
import {
  PDP_TYPE_OPTIONS,
  AUTH_TYPE_OPTIONS,
  VLAN_OPTIONS,
  isCarrierProfile,
} from "@/types/wan-profiles";

// =============================================================================
// Props
// =============================================================================

interface WanProfileEditCardProps {
  profile: WanProfile;
  isSaving: boolean;
  /** Backend data source. On "at" (AT-only modems), the wmmd-only controls
   *  — default route, IP passthrough, VLAN mapping — have no equivalent and
   *  are hidden, since saving them would be a silent no-op. */
  dataSource: "rdb" | "at";
  onSave: (index: number, request: WanProfileSaveRequest) => Promise<boolean>;
  onCancel: () => void;
}

// =============================================================================
// Loading Skeleton
// =============================================================================

function WanProfileEditSkeleton() {
  return (
    <Card className="@container/card">
      <CardHeader>
        <CardTitle>Edit Profile</CardTitle>
        <CardDescription>Loading profile configuration...</CardDescription>
      </CardHeader>
      <CardContent>
        <div className="grid gap-4">
          <div className="grid @md/card:grid-cols-2 grid-cols-1 gap-4">
            <div className="space-y-2">
              <Skeleton className="h-4 w-20" />
              <Skeleton className="h-9 w-full" />
            </div>
            <div className="space-y-2">
              <Skeleton className="h-4 w-16" />
              <Skeleton className="h-9 w-full" />
            </div>
          </div>
          <div className="grid @md/card:grid-cols-2 grid-cols-1 gap-4">
            <div className="space-y-2">
              <Skeleton className="h-4 w-24" />
              <Skeleton className="h-9 w-full" />
            </div>
            <div className="space-y-2">
              <Skeleton className="h-4 w-24" />
              <Skeleton className="h-9 w-full" />
            </div>
          </div>
          <Skeleton className="h-px w-full" />
          <div className="space-y-3">
            {Array.from({ length: 4 }).map((_, i) => (
              <div key={i} className="flex justify-between">
                <Skeleton className="h-4 w-24" />
                <Skeleton className="h-4 w-32" />
              </div>
            ))}
          </div>
          <div className="flex gap-2">
            <Skeleton className="h-9 w-28" />
            <Skeleton className="h-9 w-20" />
          </div>
        </div>
      </CardContent>
    </Card>
  );
}

// =============================================================================
// Component
// =============================================================================

// When the loaded profile has no APN set, fall back to the MNO preset that
// matches the inserted SIM's MCC/MNC. Keeps the user one field shorter to fill
// on first setup — they can still type over it. Carrier-managed profiles bypass
// this — their APN is dictated by the network and shouldn't be overwritten.
function seedApn(
  profile: WanProfile,
  carrier: boolean,
  imsi: string | undefined,
): { apn: string; preset: MnoPreset | null } {
  if (carrier || profile.apn.trim() || !imsi) {
    return { apn: profile.apn, preset: null };
  }
  const presetId = suggestPresetFromImsi(imsi);
  const preset = presetId
    ? MNO_PRESETS.find((p) => p.id === presetId) ?? null
    : null;
  return { apn: preset ? preset.apn_name : profile.apn, preset };
}

export default function WanProfileEditCard(props: WanProfileEditCardProps) {
  // IMSI from the live modem status — feeds the APN preset suggestion below.
  const { data: modemData } = useModemStatus();
  const imsi = modemData?.device?.imsi;

  // The save flash lives out here, above the remount boundary, so the re-seed
  // that follows a successful save doesn't cut the "Saved!" indicator short.
  const { saved, markSaved } = useSaveFlash();

  if (!props.profile) return <WanProfileEditSkeleton />;

  // The form seeds every field from `profile` (plus the IMSI-derived APN) once,
  // at mount. Keying on that seed data remounts the form whenever it changes —
  // a fresh fetch, the optimistic merge after a save, or a switch to another
  // slot — which re-seeds the fields without a sync effect.
  return (
    <WanProfileEditForm
      key={`${JSON.stringify(props.profile)}|${imsi ?? ""}`}
      {...props}
      imsi={imsi}
      saved={saved}
      markSaved={markSaved}
    />
  );
}

interface WanProfileEditFormProps extends WanProfileEditCardProps {
  imsi: string | undefined;
  saved: boolean;
  markSaved: () => void;
}

function WanProfileEditForm({
  profile,
  isSaving,
  dataSource,
  onSave,
  imsi,
  saved,
  markSaved,
  onCancel,
}: WanProfileEditFormProps) {
  const carrier = isCarrierProfile(profile);
  // wmmd-only controls have no AT equivalent — hide them on AT-only modems.
  const showWmmdControls = dataSource === "rdb";

  const seed = seedApn(profile, carrier, imsi);

  // --- Form state ---
  const [name, setName] = useState(profile.name);
  const [apn, setApn] = useState(seed.apn);
  const [pdpType, setPdpType] = useState(profile.pdp_type);
  const [authType, setAuthType] = useState(profile.auth_type);
  const [username, setUsername] = useState(profile.username);
  const [password, setPassword] = useState("");
  const [mtu, setMtu] = useState(profile.mtu !== null ? String(profile.mtu) : "");
  const [modemProfile, setModemProfile] = useState(String(profile.modem_profile));
  const [ipPassthrough, setIpPassthrough] = useState(profile.ip_passthrough);
  const [defaultRoute, setDefaultRoute] = useState(profile.default_route);
  const [vlanIndex, setVlanIndex] = useState(profile.vlan_index ?? "");

  // --- UI state ---
  const [showPassword, setShowPassword] = useState(false);
  const [apnError, setApnError] = useState("");
  const [mtuError, setMtuError] = useState("");
  // Track auto-fill source so the UI can hint "Đã tự điền từ {Viettel}" below the input.
  // Cleared when the user edits the APN field (signals an intentional override).
  const [autoFilledPreset, setAutoFilledPreset] = useState<MnoPreset | null>(
    seed.preset,
  );

  // --- Validation ---
  const validateForm = (): boolean => {
    let valid = true;

    if (!apn.trim()) {
      setApnError("APN is required");
      valid = false;
    } else {
      setApnError("");
    }

    const mtuNum = mtu.trim() ? parseInt(mtu, 10) : null;
    if (mtu.trim() && (isNaN(mtuNum!) || mtuNum! < 1 || mtuNum! > 1500)) {
      setMtuError("MTU must be between 1 and 1500");
      valid = false;
    } else {
      setMtuError("");
    }

    return valid;
  };

  const handleSubmit = async (e: FormEvent) => {
    e.preventDefault();
    if (!validateForm()) return;

    const request: WanProfileSaveRequest = {
      name: name.trim(),
      apn: apn.trim(),
      pdp_type: pdpType,
      auth_type: authType,
      username: authType !== "none" ? username.trim() : "",
      password: authType !== "none" ? password : "",
      mtu: mtu.trim() ? parseInt(mtu, 10) : null,
      ip_passthrough: ipPassthrough,
      modem_profile: parseInt(modemProfile, 10),
      default_route: defaultRoute,
      vlan_index: vlanIndex,
    };

    const success = await onSave(profile.index, request);
    if (success) {
      markSaved();
      toast.success(`Profile ${profile.index} saved successfully`);
    } else {
      toast.error(`Failed to save profile ${profile.index}`);
    }
  };

  const carrierTypeLabel =
    profile.apn_type === "ims"
      ? "IMS (Voice over LTE)"
      : profile.apn_type === "emergency"
        ? "Emergency Services (SOS)"
        : null;

  return (
    <Card className="@container/card">
      <CardHeader>
        <CardTitle>Edit Profile {profile.index}</CardTitle>
        <CardDescription>
          {carrier && carrierTypeLabel
            ? `Carrier-provisioned profile: ${carrierTypeLabel}`
            : `Configure APN, authentication, and connection settings for profile ${profile.index}.`}
        </CardDescription>
      </CardHeader>
      <CardContent>
        {carrier && (
          <Alert className="mb-4">
            <InfoIcon />
            <AlertTitle>Carrier-Provisioned Profile</AlertTitle>
            <AlertDescription>
              This profile is managed by your carrier and cannot be edited.
              Changes to IMS and emergency profiles may disrupt voice and
              emergency services.
            </AlertDescription>
          </Alert>
        )}

        <fieldset disabled={carrier || undefined}>
          <form className="grid gap-4" onSubmit={handleSubmit}>
            <FieldSet>
              <FieldGroup>
                {/* Row 1: Name + APN */}
                <div className="grid @md/card:grid-cols-2 grid-cols-1 grid-flow-row gap-4">
                  <Field>
                    <FieldLabel htmlFor={`wp-name-${profile.index}`}>
                      Name
                    </FieldLabel>
                    <Input
                      id={`wp-name-${profile.index}`}
                      placeholder="My Data Profile"
                      value={name}
                      onChange={(e) => setName(e.target.value)}
                      disabled={isSaving}
                    />
                  </Field>

                  <Field data-invalid={apnError ? true : undefined}>
                    <FieldLabel htmlFor={`wp-apn-${profile.index}`}>
                      APN *
                    </FieldLabel>
                    <Input
                      id={`wp-apn-${profile.index}`}
                      placeholder="fast.t-mobile.com"
                      value={apn}
                      onChange={(e) => {
                        setApn(e.target.value);
                        // User-edit signals an intentional override — drop the
                        // "auto-filled from preset" hint so we don't claim a
                        // value we no longer set.
                        if (autoFilledPreset) setAutoFilledPreset(null);
                        if (apnError) setApnError("");
                      }}
                      disabled={isSaving}
                      required
                      aria-required="true"
                      aria-invalid={!!apnError}
                    />
                    {apnError ? (
                      <FieldError>{apnError}</FieldError>
                    ) : autoFilledPreset ? (
                      <p className="text-xs text-muted-foreground">
                        Đã tự điền theo nhà mạng <strong>{autoFilledPreset.label}</strong>. Sửa nếu cần.
                      </p>
                    ) : null}
                  </Field>
                </div>

                {/* Row 2: PDP Type + Auth Type */}
                <div className="grid @md/card:grid-cols-2 grid-cols-1 grid-flow-row gap-4">
                  <Field>
                    <FieldLabel htmlFor={`wp-pdp-${profile.index}`}>
                      PDP Type
                    </FieldLabel>
                    <Select
                      value={pdpType}
                      onValueChange={setPdpType}
                      disabled={isSaving}
                    >
                      <SelectTrigger
                        id={`wp-pdp-${profile.index}`}
                        aria-label="PDP Type"
                      >
                        <SelectValue placeholder="Select PDP type" />
                      </SelectTrigger>
                      <SelectContent>
                        {PDP_TYPE_OPTIONS.map((opt) => (
                          <SelectItem key={opt.value} value={opt.value}>
                            {opt.label}
                          </SelectItem>
                        ))}
                      </SelectContent>
                    </Select>
                  </Field>

                  <Field>
                    <FieldLabel htmlFor={`wp-auth-${profile.index}`}>
                      Auth Type
                    </FieldLabel>
                    <Select
                      value={authType}
                      onValueChange={(v) => {
                        setAuthType(v);
                        if (v === "none") {
                          setUsername("");
                          setPassword("");
                        }
                      }}
                      disabled={isSaving}
                    >
                      <SelectTrigger
                        id={`wp-auth-${profile.index}`}
                        aria-label="Authentication Type"
                      >
                        <SelectValue placeholder="Select auth type" />
                      </SelectTrigger>
                      <SelectContent>
                        {AUTH_TYPE_OPTIONS.map((opt) => (
                          <SelectItem key={opt.value} value={opt.value}>
                            {opt.label}
                          </SelectItem>
                        ))}
                      </SelectContent>
                    </Select>
                  </Field>
                </div>

                {/* Row 3: Username + Password (conditional on auth type) */}
                {authType !== "none" && (
                  <div className="grid @md/card:grid-cols-2 grid-cols-1 grid-flow-row gap-4">
                    <Field>
                      <FieldLabel htmlFor={`wp-user-${profile.index}`}>
                        Username
                      </FieldLabel>
                      <Input
                        id={`wp-user-${profile.index}`}
                        placeholder="Username"
                        value={username}
                        onChange={(e) => setUsername(e.target.value)}
                        disabled={isSaving}
                        autoComplete="username"
                      />
                    </Field>

                    <Field>
                      <FieldLabel htmlFor={`wp-pass-${profile.index}`}>
                        Password
                      </FieldLabel>
                      <div className="relative">
                        <Input
                          id={`wp-pass-${profile.index}`}
                          type={showPassword ? "text" : "password"}
                          placeholder="Password"
                          value={password}
                          onChange={(e) => setPassword(e.target.value)}
                          disabled={isSaving}
                          autoComplete="new-password"
                          className="pr-10"
                        />
                        <Button
                          type="button"
                          variant="ghost"
                          size="icon-sm"
                          className="absolute right-1 top-1/2 -translate-y-1/2 text-muted-foreground hover:text-foreground"
                          onClick={() => setShowPassword((v) => !v)}
                          tabIndex={-1}
                          aria-label={
                            showPassword ? "Hide password" : "Show password"
                          }
                        >
                          {showPassword ? (
                            <EyeOffIcon className="size-4" />
                          ) : (
                            <EyeIcon className="size-4" />
                          )}
                        </Button>
                      </div>
                    </Field>
                  </div>
                )}

                {/* Row 4: MTU + Modem Profile */}
                <div className="grid @md/card:grid-cols-2 grid-cols-1 grid-flow-row gap-4">
                  <Field data-invalid={mtuError ? true : undefined}>
                    <FieldLabel htmlFor={`wp-mtu-${profile.index}`}>
                      MTU
                    </FieldLabel>
                    <Input
                      id={`wp-mtu-${profile.index}`}
                      type="number"
                      placeholder="1500 (default)"
                      min={1}
                      max={1500}
                      value={mtu}
                      onChange={(e) => {
                        setMtu(e.target.value);
                        if (mtuError) setMtuError("");
                      }}
                      disabled={isSaving}
                      aria-invalid={!!mtuError}
                    />
                    {mtuError && <FieldError>{mtuError}</FieldError>}
                  </Field>

                  <Field>
                    <FieldLabel htmlFor={`wp-cid-${profile.index}`}>
                      Modem Profile
                    </FieldLabel>
                    <Select
                      value={modemProfile}
                      onValueChange={setModemProfile}
                      disabled={isSaving}
                    >
                      <SelectTrigger
                        id={`wp-cid-${profile.index}`}
                        aria-label="Modem Profile (CID)"
                      >
                        <SelectValue placeholder="Select CID" />
                      </SelectTrigger>
                      <SelectContent>
                        {[1, 2, 3, 4, 5, 6].map((cid) => (
                          <SelectItem key={cid} value={String(cid)}>
                            CID {cid}
                          </SelectItem>
                        ))}
                      </SelectContent>
                    </Select>
                  </Field>
                </div>

                {/* Rows 5-6 — wmmd-only controls; hidden on AT-only modems */}
                {showWmmdControls && (
                  <>
                {/* Row 5: VLAN Mapping (full width) */}
                <Field>
                  <FieldLabel htmlFor={`wp-vlan-${profile.index}`}>
                    Map to LAN / VLAN
                  </FieldLabel>
                  <Select
                    value={vlanIndex || "_default"}
                    onValueChange={(v) => setVlanIndex(v === "_default" ? "" : v)}
                    disabled={isSaving}
                  >
                    <SelectTrigger
                      id={`wp-vlan-${profile.index}`}
                      aria-label="VLAN mapping"
                    >
                      <SelectValue placeholder="Default (bridge0)" />
                    </SelectTrigger>
                    <SelectContent>
                      {VLAN_OPTIONS.map((opt) => (
                        <SelectItem key={opt.value} value={opt.value || "_default"}>
                          {opt.label}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </Field>

                {/* Row 6: Default Route + IP Passthrough toggles */}
                <div className="grid @md/card:grid-cols-2 grid-cols-1 gap-4">
                  <Field orientation="horizontal">
                    <div className="flex flex-auto items-center gap-1.5">
                      <FieldLabel htmlFor={`wp-default-route-${profile.index}`}>
                        Default Route
                      </FieldLabel>
                      <Tooltip>
                        <TooltipTrigger asChild>
                          <button
                            type="button"
                            className="inline-flex"
                            aria-label="What is Default Route?"
                          >
                            <TbInfoCircleFilled className="size-4 text-info" />
                          </button>
                        </TooltipTrigger>
                        <TooltipContent>
                          <p className="max-w-56">
                            Sends this device&apos;s internet traffic through
                            this profile&apos;s connection. Only one profile can
                            be the default route at a time.
                          </p>
                        </TooltipContent>
                      </Tooltip>
                    </div>
                    <Switch
                      id={`wp-default-route-${profile.index}`}
                      checked={defaultRoute}
                      onCheckedChange={setDefaultRoute}
                      disabled={isSaving}
                      aria-label="Set as default route"
                    />
                  </Field>

                  <Field orientation="horizontal">
                    <div className="flex flex-auto items-center gap-1.5">
                      <FieldLabel htmlFor={`wp-passthrough-${profile.index}`}>
                        IP Passthrough
                      </FieldLabel>
                      <Tooltip>
                        <TooltipTrigger asChild>
                          <button
                            type="button"
                            className="inline-flex"
                            aria-label="What is IP Passthrough?"
                          >
                            <TbInfoCircleFilled className="size-4 text-info" />
                          </button>
                        </TooltipTrigger>
                        <TooltipContent>
                          <p className="max-w-56">
                            Hands the modem&apos;s public WAN IP straight to one
                            connected device, bypassing NAT. Useful for a
                            downstream router, console, or server.
                          </p>
                        </TooltipContent>
                      </Tooltip>
                    </div>
                    <Switch
                      id={`wp-passthrough-${profile.index}`}
                      checked={ipPassthrough}
                      onCheckedChange={setIpPassthrough}
                      disabled={isSaving}
                      aria-label="Enable IP passthrough"
                    />
                  </Field>
                </div>
                  </>
                )}
              </FieldGroup>
            </FieldSet>

            {/* --- Actions --- */}
            <div className="flex items-center gap-2">
              {!carrier && (
                <SaveButton
                  type="submit"
                  isSaving={isSaving}
                  saved={saved}
                  label="Save Profile"
                />
              )}
              <Button
                type="button"
                variant="outline"
                onClick={onCancel}
                disabled={isSaving}
              >
                {carrier ? "Back" : "Cancel"}
              </Button>
            </div>
          </form>
        </fieldset>
      </CardContent>
    </Card>
  );
}
