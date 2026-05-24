# QManager-VN v0.4.0-vn — i18n EN/VI với language toggle 🇻🇳 🇬🇧

Phase F.3 — đa ngôn ngữ. Mặc định Tiếng Việt, có nút chuyển sang English với cờ.

## 🌐 Đa ngôn ngữ EN / VI

### Language Toggle
- **Dropdown nút cờ** đặt cạnh "QManager Admin" trong sidebar header
- 2 ngôn ngữ: 🇻🇳 **Tiếng Việt** (mặc định) và 🇬🇧 **English**
- Persist preference qua `localStorage` (`qmanager_vn_lang`)
- Cross-tab sync qua native `storage` event
- Cross-component sync trong cùng tab qua module-level event bus

### Mặc định Tiếng Việt
- Lần đầu mở app: detect `navigator.language` — nếu là `vi-*` → VI, else → fallback VI (audience VN-first)
- User chọn ngôn ngữ → lưu localStorage, áp dụng lập tức (không reload)
- Missing VN key → fallback EN tự động (không hiện raw key)

### Strings đã translated
**Sidebar (đầy đủ):**
- Home, SMS Center, Custom Profiles, Connection Scenarios
- Band Locking, Tower Locking, Frequency Locking
- Cell Scanner, Neighboring Cells, Frequency Calculator
- Settings, APN Management, Network Priority, IMEI Settings, FPLMN Settings
- System Settings, Logs, Connection Quality, Software Update
- Ethernet Status, TTL & MTU Settings, Custom DNS
- Network Events, Latency Monitor, SMS Alerts, Watchdog
- About Device, Support, Donate to the Project

**Dashboard top row (5 widgets):**
- Network Status: RAT labels (5G + LTE / 5G Standalone / LTE+ / Low Power / No 4G/5G), uptime prefix
- Temperature, SMS Received, Internet Quality, Device Information
- Tier labels: Best / Good / Fair / Poor / No data / Offline
- "Tap for details", "avg N ms", "Awaiting samples", "No internet"

**Dashboard Row 1 (3 cards):**
- 4G Primary Status, 5G Primary Status (titles + descriptions + carrier count message)

**Dashboard Row 2 (3 cards):**
- System Health card title + "Run Diagnostics" button + "System Diagnostics" dialog title

**Misc:**
- "Unable to reach the modem..." error banner

### Chưa translate (follow-up)
- Deep page strings: APN form labels, Band Lock controls, IMEI settings, SMS center detail, Network Priority, FPLMN, Connection Scenarios, Watchdog detail, System Settings nested forms, About Device card detail rows, AutolockCard threshold form labels
- These keep English in current release — pattern hết để translate dần khi cần

## 🏗️ Infrastructure

**New files:**
- `lib/i18n/en.json` (~3 KB) — base translation set
- `lib/i18n/vi.json` (~3 KB) — Vietnamese
- `hooks/use-i18n.ts` — `useT()` hook returning `{ lang, setLang, t }`. Pure JSON lookup + interpolation, no external dep.
- `components/language-toggle.tsx` — flag dropdown component (inline SVG flags VN/UK, no emoji to avoid OS rendering differences)

**Modified:**
- `components/app-sidebar.tsx` — `buildData(t)` factory inside component renders translated menu titles; LanguageToggle mounted next to QManager logo
- All dashboard widgets: `useT` hook + `t("...")` for visible labels

## 📥 Cập nhật

OTA từ WebUI: **System Settings → Software Update → Download → Install**.

```sh
curl -fsSL -o /tmp/qmanager-installer.sh \
  https://github.com/tuanlongsav/QManager-VN/raw/refs/heads/main/qmanager-installer.sh && \
  bash /tmp/qmanager-installer.sh
```

Sau cài, click cờ ở sidebar header để toggle EN ↔ VI. Refresh không cần.

## 🙏 Credit

Upstream [dr-dolomite/QManager-RM520N](https://github.com/dr-dolomite/QManager-RM520N).
**License:** MIT + Commons Clause.
