// =============================================================================
// sms.ts — SMS Center Types
// =============================================================================
// TypeScript interfaces for the SMS Center CGI endpoint.
//
// Backend endpoint: GET/POST /cgi-bin/quecmanager/cellular/sms.sh
//
// Note: The SmsMessage shape matches the JSON output of `sms_tool -j recv`.
// Verify field names against actual device output and adjust if needed.
// =============================================================================

/** A single (possibly merged multi-part) SMS message */
export interface SmsMessage {
  /** Storage indexes for all parts of this message (used for deletion) */
  indexes: number[];
  /** Sender phone number or alphanumeric ID */
  sender: string;
  /** Message content (concatenated if multi-part) */
  content: string;
  /** Timestamp string (format: "MM/DD/YY HH:MM:SS") */
  timestamp: string;
  /**
   * Raw UCS-2 hex content joined across all parts (inbox only).
   * Backend supplies this from AT+CMGL "ALL" because sms_tool's UCS-2
   * decoder corrupts code points U+0080–U+00FF (Vietnamese precomposed
   * chars like à/á/ò/ý). Frontend decodes this to overwrite `content`.
   */
  content_hex?: string;
}

/** Storage status info */
export interface SmsStorage {
  /** Number of messages currently stored */
  used: number;
  /** Maximum storage capacity */
  total: number;
}

/** Response from GET /cgi-bin/quecmanager/cellular/sms.sh */
export interface SmsInboxResponse {
  success: boolean;
  messages: SmsMessage[];
  storage: SmsStorage;
  error?: string;
  detail?: string;
}

/** Generic POST response */
export interface SmsActionResponse {
  success: boolean;
  error?: string;
  detail?: string;
}
