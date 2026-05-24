# QManager-VN v0.4.1-vn — Xoá Auto cell-lock + thay bằng Band Locking Settings

User feedback v0.4.0-vn: Auto cell-lock không còn cần thiết → xoá toàn bộ. Thay vào dashboard slot bằng **Band Locking Settings** card hiển thị Band Failover toggle/status + Active LTE/5G Bands/Channels.

## 🗑️ Xoá Auto cell-lock

Xoá toàn bộ stack (daemon, CGI, UI, config, sudoers, i18n keys):

- `scripts/usr/bin/qmanager_autolock` — daemon
- `scripts/www/cgi-bin/quecmanager/cellular/autolock.sh` — CGI
- `scripts/etc/systemd/system/qmanager-autolock.service` — systemd unit
- `hooks/use-autolock.ts`, `types/autolock.ts` — frontend hook + types
- `components/cellular/tower-locking/autolock-card.tsx` — UI component
- `lib/i18n/{en,vi}.json` — `autolock` section + `autoCellLock` key
- `scripts/install_rm520n.sh` — gỡ `qmanager-autolock` khỏi `UCI_GATED_SERVICES`
- `scripts/etc/sudoers.d/qmanager` — gỡ comment block về autolock

Không ảnh hưởng tới Tower Locking, Band Locking, Frequency Locking thủ công — tất cả vẫn hoạt động bình thường ở trang `/cellular/cell-locking`.

## ✨ Band Locking Settings card lên Dashboard

Reuse `BandSettingsComponent` (đã có sẵn từ Band Locking page) — không tạo component mới. Wire vào Dashboard Row 1 slot 3 (chỗ AutolockCard cũ).

**Hiển thị:**
- **Title:** Band Locking Settings (translated: "Cài đặt khóa Band")
- **Description:** "Restrict the modem to specific LTE and 5G bands. Enable failover to fall back to all bands if locked bands lose signal."
- **Band Failover** — switch on/off (toggle gọi `useBandLocking.toggleFailover`)
- **Band Failover Status** — badge: Disabled / Ready / Monitoring / Fallback Active
- **Active LTE Bands** — e.g. "B3" (derived từ `carrier_components.filter(c => c.technology === "LTE")`)
- **Active LTE Channels** — EARFCN list, e.g. "1300"
- **Active 5G Bands** — e.g. "N78"
- **Active 5G Channels** — ARFCN list, e.g. "648096"

Data sources:
- `useBandLocking()` → `failover` state + `toggleFailover` mutation
- `useModemStatus().data.network.carrier_components` → derived active bands/channels

## 📦 Files changed

**Deleted (7):**
- `scripts/usr/bin/qmanager_autolock`
- `scripts/www/cgi-bin/quecmanager/cellular/autolock.sh`
- `scripts/etc/systemd/system/qmanager-autolock.service`
- `hooks/use-autolock.ts`
- `types/autolock.ts`
- `components/cellular/tower-locking/autolock-card.tsx`

**Modified (5):**
- `components/dashboard/home-component.tsx` — replace AutolockCard with BandSettingsComponent
- `lib/i18n/en.json` + `lib/i18n/vi.json` — add band locking keys, remove autolock section
- `scripts/install_rm520n.sh` — gỡ qmanager-autolock khỏi UCI_GATED_SERVICES
- `scripts/etc/sudoers.d/qmanager` — clean autolock comment

**Verified:**
- 119 shell scripts pass syntax check (–2 từ xoá daemon + CGI)
- Không còn broken import
- Tower Locking + Band Locking page riêng vẫn hoạt động đầy đủ

## 📥 Cập nhật

OTA từ WebUI: **System Settings → Software Update → Download → Install**.

Sau cài, dashboard Row 1 sẽ hiển thị: **4G Primary Status** | **5G Primary Status** | **Band Locking Settings** (thay vì Auto cell-lock).

## 🙏 Credit

Upstream [dr-dolomite/QManager-RM520N](https://github.com/dr-dolomite/QManager-RM520N).
**License:** MIT + Commons Clause.
