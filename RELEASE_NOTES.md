# QManager-VN v0.3.1-vn — Dashboard refactor (Signal Status section + System Health merge)

User feedback v0.3.0-vn: 4 widget chưa đều kích thước, dưới đó dashboard rườm rà với nhiều section nhỏ. Bản này tinh gọn theo direction mới — 1 section "Signal Status" gộp các thông tin liên quan, System Health gộp diagnostics, xoá Live Latency để nhẹ hơn.

## ✨ Thay đổi UI

### Top row 4 widget — đồng đều kích thước
- Tất cả 4 widget (Network / Temperature / SMS / Internet Quality) cùng `min-h-[200px]`, icon size 12, value text 4xl bold.
- Label uppercase tracking semibold đồng nhất.
- Network Status compact giờ dùng cùng cỡ icon + cỡ font với 3 widget khác.

### Xoá Live Latency and Speed Test (F.2.B)
- Component dashboard `live-latency.tsx` đã xoá.
- Component `speedtest-dialog.tsx` đã xoá.
- Hook `use-speedtest.ts` + types đã xoá.
- 4 CGI scripts `speedtest_*.sh` đã xoá.
- Speedtest CLI download khỏi installer (gỡ ~5MB Ookla binary).
- Lighter dashboard — internet quality vẫn show qua widget Internet Quality (tier + avg latency).

### Signal Status section (F.2.D)
- Section duy nhất dưới 4 widget top row, label "Signal Status".
- Grid 2×2 gồm **4 sub-cards**:
  - **4G Primary Status** (LTE detail card)
  - **5G Primary Status** (NR detail card)
  - **Recent Activities** (timeline events)
  - **Signal Quality Monitor** (NEW) — bar chart hiển thị RSRP / RSRQ / SINR với tier (Excellent / Good / Fair / Poor) + raw value
- Auto chọn 5G NR nếu đang connected, fallback LTE.

### System Health merge (F.2.E)
- Card "Device Metrics" → đổi tên **"System Health"**.
- Thêm button "Run Diagnostics" trong header → mở dialog chứa toàn bộ giao diện System Health Check (categories, tests, bundle download).
- Xoá page riêng `/system-settings/system-health-check` + sidebar entry.
- Xoá Signal History chart full-width khỏi dashboard (không còn liên quan sau khi gộp section).

### Bố cục cân đối (F.2.F)
- Hàng cuối: **System Health** + **Device Information** trong grid 2-col đều nhau, cùng `h-full`.

## 🗑️ Files removed

- `components/dashboard/live-latency.tsx`
- `components/dashboard/speedtest-dialog.tsx`
- `components/dashboard/signal-history.tsx`
- `hooks/use-speedtest.ts`
- `hooks/use-signal-history.ts`
- `types/speedtest.ts`
- `scripts/www/cgi-bin/quecmanager/at_cmd/speedtest_{start,status,check,servers}.sh`
- `scripts/www/cgi-bin/quecmanager/at_cmd/fetch_signal_history.sh`
- `app/system-settings/system-health-check/`

## 🚧 Đến

Bản v0.4.0-vn sẽ thêm: **i18n EN/VI + language toggle** (cờ Việt/Anh cạnh user menu).

## 📥 Cài đặt / Cập nhật

OTA từ WebUI: **System Settings → Software Update → Download → Install**.

```sh
curl -fsSL -o /tmp/qmanager-installer.sh \
  https://github.com/tuanlongsav/QManager-VN/raw/refs/heads/main/qmanager-installer.sh && \
  bash /tmp/qmanager-installer.sh
```

## 🙏 Credit

Upstream [dr-dolomite/QManager-RM520N](https://github.com/dr-dolomite/QManager-RM520N).
**License:** MIT + Commons Clause.
