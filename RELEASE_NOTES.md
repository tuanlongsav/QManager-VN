# QManager-VN v0.3.0-vn — Dashboard UX overhaul + APN auto-fill

Bản này tập trung vào trải nghiệm hàng ngày — lấy cảm hứng từ layout 4-widget top-row của Simple Admin (rgmii-toolkit) mà vẫn giữ chiều sâu Pro mode của QManager.

## ✨ Tính năng mới

### APN Management tự điền theo nhà mạng (Phase F.1.A)
- Mở form APN profile lần đầu, nếu APN trống và SIM có IMSI VN → tự fill `m3-world` (Vinaphone) / `v-internet` (Viettel) / `m-i-internet` (Mobifone) / `internet` (Vietnamobile) / `v-internet` (Wintel) theo MCC/MNC.
- Hint nhỏ dưới input: "Đã tự điền theo nhà mạng {Viettel}. Sửa nếu cần." User edit thì hint biến mất.
- Carrier-managed profile vẫn read-only — không bị override.
- KHÔNG động vào profile đã có APN trước đó.

### Dashboard Home — top row 4 widget (Phase F.1.B + F.1.C)
4 card vuông cùng size (responsive 1/2/4 cột), thay thế Network Status full + UiMode toggle:

1. **Network Status (compact)** — big RAT icon (5G / LTE+ / LTE / 3G) + carrier name + public IPv4 + uptime. Dot chỉ trạng thái internet ở góc.
2. **Temperature** — số °C to giống Simple Admin, color tier (cool/warm/hot).
3. **SMS Received** — count messages, click → SMS center.
4. **Internet Quality** — tier (Excellent / Good / Fair / Poor / Offline) + avg latency 30 phút. Tooltip detail: loss %, sample count, jitter.

### Xoá Simple Mode (Phase F.1.B)
- Toggle Simple/Pro đã được gỡ — dashboard luôn show full content.
- LTE/NR/SCC detail, Device Status, Device Metrics, Live Latency chart, Recent Activities, Signal History luôn hiển thị.
- `hooks/use-ui-mode.ts` + `components/dashboard/ui-mode-toggle.tsx` đã xoá.

### Temperature widget ở trang About Device (Phase F.1.D)
- Cùng component `TemperatureWidget` mount ở About Device page (grid 3-col: Temperature + Device Information + About QManager).
- User xem nhiệt độ modem nhanh ở 2 nơi: Home dashboard + About Device.

## 🛠️ Internal changes

- New: `components/dashboard/temperature-widget.tsx`, `sms-received-widget.tsx`, `internet-quality-widget.tsx`, `network-status-compact.tsx`
- Modified: `components/dashboard/home-component.tsx` — restructure 4-widget top row + Pro layout always-on
- Modified: `components/cellular/settings/apn-management/wan-profile-edit.tsx` — auto-fill effect
- Modified: `components/about-device/about-device.tsx` — mount TemperatureWidget
- Deleted: `hooks/use-ui-mode.ts`, `components/dashboard/ui-mode-toggle.tsx`, `components/dashboard/network-status.tsx` (replaced by compact variant)

## 📥 Cài đặt / Cập nhật

OTA từ WebUI: **System Settings → Software Update → Download → Install**. Sau reboot UI hiển thị `v0.3.0-vn`.

Fresh install:
```sh
curl -fsSL -o /tmp/qmanager-installer.sh \
  https://github.com/tuanlongsav/QManager-VN/raw/refs/heads/main/qmanager-installer.sh && \
  bash /tmp/qmanager-installer.sh
```

## 🙏 Credit

Upstream [dr-dolomite/QManager-RM520N](https://github.com/dr-dolomite/QManager-RM520N). VN reference [iamromulan/quectel-rgmii-toolkit](https://github.com/iamromulan/quectel-rgmii-toolkit) + fork [tuanlongsav/quectel-rgmii-toolkit](https://github.com/tuanlongsav/quectel-rgmii-toolkit).

**License:** MIT + Commons Clause.
