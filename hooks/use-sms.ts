"use client";

import { useState, useCallback, useRef, useEffect } from "react";
import { authFetch } from "@/lib/auth-fetch";
import { fetchJsonFixed } from "@/lib/fix-mixed-utf8";
import type {
  SmsMessage,
  SmsStorage,
  SmsInboxResponse,
  SmsActionResponse,
} from "@/types/sms";

// =============================================================================
// useSms — SMS Inbox + Outbox Fetch & Mutation Hook
// =============================================================================
// Fetches inbox (modem-backed) and outbox (local JSON file) in parallel.
// Provides sendSms, deleteSms, deleteAllSms for mutations against either
// folder. Send appends to outbox automatically (backend handles it).
//
// Backend endpoint:
//   GET  /cgi-bin/quecmanager/cellular/sms.sh?folder=inbox|outbox
//   POST /cgi-bin/quecmanager/cellular/sms.sh   { action, folder?, ... }
// =============================================================================

const CGI_ENDPOINT = "/cgi-bin/quecmanager/cellular/sms.sh";

export type SmsFolder = "inbox" | "outbox";

export interface SmsData {
  messages: SmsMessage[];
  storage: SmsStorage;
}

export interface UseSmsReturn {
  /** Current inbox data (null before first fetch) */
  data: SmsData | null;
  /** Current outbox data (null before first fetch) */
  outbox: SmsData | null;
  /** True while initial fetch is in progress (either folder) */
  isLoading: boolean;
  /** True while a send/delete operation is in progress */
  isSaving: boolean;
  /** Error message if any operation failed */
  error: string | null;
  /** Send an SMS message. Returns true on success. */
  sendSms: (phone: string, message: string) => Promise<boolean>;
  /** Delete messages by storage indexes from the given folder. Returns true on success. */
  deleteSms: (indexes: number[], folder?: SmsFolder) => Promise<boolean>;
  /** Delete all messages in the given folder. Returns true on success. */
  deleteAllSms: (folder?: SmsFolder) => Promise<boolean>;
  /** Re-fetch both inbox + outbox. Pass true for silent (no loading skeleton). */
  refresh: (silent?: boolean) => void;
}

export function useSms(): UseSmsReturn {
  const [data, setData] = useState<SmsData | null>(null);
  const [outbox, setOutbox] = useState<SmsData | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [isSaving, setIsSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const mountedRef = useRef(true);

  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
    };
  }, []);

  // ---------------------------------------------------------------------------
  // Fetch one folder
  // ---------------------------------------------------------------------------
  const fetchFolder = useCallback(
    async (folder: SmsFolder): Promise<void> => {
      const url = folder === "outbox" ? `${CGI_ENDPOINT}?folder=outbox` : CGI_ENDPOINT;
      const resp = await authFetch(url);
      if (!resp.ok) {
        throw new Error(`HTTP ${resp.status}: ${resp.statusText}`);
      }
      // Use fixed JSON parser — sms_tool emits some VN chars as stray
      // Latin-1 bytes mixed with valid UTF-8, which would otherwise render
      // as � in the browser. See lib/fix-mixed-utf8.ts.
      const json = await fetchJsonFixed<SmsInboxResponse>(resp);
      if (!mountedRef.current) return;
      if (!json.success) {
        throw new Error(json.detail || json.error || "Failed to fetch SMS");
      }
      const next: SmsData = {
        messages: json.messages || [],
        storage: json.storage || { used: 0, total: 0 },
      };
      if (folder === "outbox") {
        setOutbox(next);
      } else {
        setData(next);
      }
    },
    [],
  );

  // ---------------------------------------------------------------------------
  // Fetch both folders in parallel
  // ---------------------------------------------------------------------------
  const refresh = useCallback(
    async (silent = false) => {
      if (!silent) setIsLoading(true);
      setError(null);
      try {
        await Promise.all([fetchFolder("inbox"), fetchFolder("outbox")]);
      } catch (err) {
        if (!mountedRef.current) return;
        setError(err instanceof Error ? err.message : "Failed to fetch SMS");
      } finally {
        if (mountedRef.current && !silent) {
          setIsLoading(false);
        }
      }
    },
    [fetchFolder],
  );

  // Fetch on mount
  useEffect(() => {
    refresh();
  }, [refresh]);

  // ---------------------------------------------------------------------------
  // Send SMS — backend appends to outbox automatically
  // ---------------------------------------------------------------------------
  const sendSms = useCallback(
    async (phone: string, message: string): Promise<boolean> => {
      setError(null);
      setIsSaving(true);

      try {
        const resp = await authFetch(CGI_ENDPOINT, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ action: "send", phone, message }),
        });

        if (!resp.ok) {
          throw new Error(`HTTP ${resp.status}: ${resp.statusText}`);
        }

        const json: SmsActionResponse = await resp.json();
        if (!mountedRef.current) return false;

        if (!json.success) {
          setError(json.detail || json.error || "Failed to send SMS");
          return false;
        }

        // Refresh outbox immediately (sent message just appended), inbox after
        // a short delay so the modem has time to mark storage state.
        await fetchFolder("outbox").catch(() => {});
        setTimeout(() => {
          if (mountedRef.current) fetchFolder("inbox").catch(() => {});
        }, 1000);
        return true;
      } catch (err) {
        if (!mountedRef.current) return false;
        setError(err instanceof Error ? err.message : "Failed to send SMS");
        return false;
      } finally {
        if (mountedRef.current) {
          setIsSaving(false);
        }
      }
    },
    [fetchFolder],
  );

  // ---------------------------------------------------------------------------
  // Delete messages from a folder
  // ---------------------------------------------------------------------------
  const deleteSms = useCallback(
    async (indexes: number[], folder: SmsFolder = "inbox"): Promise<boolean> => {
      setError(null);
      setIsSaving(true);

      try {
        const resp = await authFetch(CGI_ENDPOINT, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ action: "delete", indexes, folder }),
        });

        if (!resp.ok) {
          throw new Error(`HTTP ${resp.status}: ${resp.statusText}`);
        }

        const json: SmsActionResponse = await resp.json();
        if (!mountedRef.current) return false;

        if (!json.success) {
          setError(json.detail || json.error || "Failed to delete message");
          return false;
        }

        await fetchFolder(folder).catch(() => {});
        return true;
      } catch (err) {
        if (!mountedRef.current) return false;
        setError(
          err instanceof Error ? err.message : "Failed to delete message",
        );
        return false;
      } finally {
        if (mountedRef.current) {
          setIsSaving(false);
        }
      }
    },
    [fetchFolder],
  );

  // ---------------------------------------------------------------------------
  // Delete all messages in a folder
  // ---------------------------------------------------------------------------
  const deleteAllSms = useCallback(
    async (folder: SmsFolder = "inbox"): Promise<boolean> => {
      setError(null);
      setIsSaving(true);

      try {
        const resp = await authFetch(CGI_ENDPOINT, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ action: "delete_all", folder }),
        });

        if (!resp.ok) {
          throw new Error(`HTTP ${resp.status}: ${resp.statusText}`);
        }

        const json: SmsActionResponse = await resp.json();
        if (!mountedRef.current) return false;

        if (!json.success) {
          setError(json.detail || json.error || "Failed to delete all messages");
          return false;
        }

        await fetchFolder(folder).catch(() => {});
        return true;
      } catch (err) {
        if (!mountedRef.current) return false;
        setError(
          err instanceof Error ? err.message : "Failed to delete all messages",
        );
        return false;
      } finally {
        if (mountedRef.current) {
          setIsSaving(false);
        }
      }
    },
    [fetchFolder],
  );

  return {
    data,
    outbox,
    isLoading,
    isSaving,
    error,
    sendSms,
    deleteSms,
    deleteAllSms,
    refresh,
  };
}
