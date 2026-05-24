# QManager-VN v0.5.0-vn — Việt hoá mở rộng, Outbox SMS, Theme toggle & Internet quality %

Bản phát hành tập trung vào trải nghiệm tiếng Việt: dịch thuật mở rộng tới toàn bộ "chrome" UI (sidebar, nav-user, About Device, Support, Cell Scanner, các card dashboard), tái cấu trúc đầu menu sidebar và thêm 3 tính năng đáng chú ý: Outbox cho SMS Center, dropdown chuyển giao diện sáng/tối cạnh nút chuyển ngôn ngữ và điểm % chất lượng kết nối Internet hiển thị cạnh tier.

## ✨ Việt hoá mở rộng

Cập nhật `lib/i18n/{en,vi}.json` với 9 namespace mới (`common.theme*`, `navUser`, `support`, `aboutDevice`, `cellInfo`, `bandSettings`, `systemHealth`, `recentActivities`, `cellScanner`, `smsCenter`) và sửa 2 lỗi đặt tên:

- `sidebar.cellScanner` → **"Quét trạm phát sóng"** (cũ: "Quét tế bào")
- `sidebar.neighbouringCells` → **"Quét trạm phát sóng lân cận"** (cũ: "Tế bào lân cận"); EN cũng cập nhật thành "Neighbor Cell Scanner" cho khớp với heading trang.

Các component được wrap `useT()` thêm:

- **`nav-user`** — toàn bộ menu user (Đổi tên hiển thị / Đổi mật khẩu / Kết nối lại mạng / Khởi động lại thiết bị / Đăng xuất), dialog title + description, toast message, aria-label
- **`support/support`** — heading, 2 card cũ (Liên hệ, Cộng đồng) và card Donate mới (xem dưới)
- **`about-device/*`** — heading + CardTitle + tất cả label hàng Network/Device/System
- **`cellular/cell-scanner/cell-scanner` + `neighbourcell/neighbourcell`** — h1 + description
- **`dashboard/rat-primary-card`** — InfoRow labels (Band Name / UL / DL / Bandwidth / PCI) reuse `accordion.*`, fallback "No active LTE/5G carrier" + pending message
- **`dashboard/recent-activities`** — CardTitle + empty state
- **`dashboard/device-metrics`** — CardTitle + 10 label hàng (Modem Temperature / CPU / Memory / Storage / Data Used / LTE/NR Cell Distance / Connection/Device Uptime), badge High Temp/CPU, dialog reset counter, tooltip Timing Advance, toast
- **`cellular/cell-data`** — CardTitle + tất cả InfoRow (ISP, APN, Network Type, Cell ID + tooltip eNodeB/gNodeB Sector, TAC + tooltip hex, Total Bandwidth, Carrier Aggregation, Active MIMO, WAN IPv4/IPv6, Primary/Secondary DNS)
- **`cellular/band-locking/band-settings`** — CardTitle + description + 6 label hàng + 5 badge trạng thái + label Switch + tooltip failover + toast
- **`cellular/sms/*`** (xem mục SMS dưới)

## 🌙 Theme toggle cạnh Language toggle

`components/theme-toggle.tsx` mới — dropdown 3 lựa chọn **Sáng / Tối / Theo hệ thống**, gắn ngay cạnh Language toggle trong sidebar header. Icon trigger dùng kỹ thuật CSS-only `Sun dark:hidden` / `Moon hidden dark:block` để tránh hydration warning của next-themes. Item đang chọn highlight `bg-accent` theo `theme` (light/dark/system), không phải `resolvedTheme`.

Đồng thời:

- Loại bỏ entry "Toggle Theme" trong menu User → giảm 1 click cho thao tác thường dùng
- Loại bỏ imports `useTheme`, `Sun`, `Moon` khỏi `nav-user.tsx`

## 💖 Donate dời vào trang Support

Trang `/support` chuyển sang grid 3 cột với card thứ 3 **Donate** chứa toàn bộ nội dung từ `DonateDialog` cũ (lời cảm ơn của Rus + nút Wise/PayPal + link GitHub Sponsors). Đồng thời:

- Xoá `components/donate-dialog.tsx`
- Xoá entry "Ủng hộ dự án" khỏi NavSecondary của sidebar (cùng toàn bộ wiring state/onClick)
- Xoá key `sidebar.donate` khỏi 2 file i18n

Lợi ích: bớt 1 entry trong sidebar luôn nằm "cuối cùng" mà người dùng ít dùng, đồng thời donate hiện rõ ràng trong trang Support — đúng ngữ cảnh.

## 📨 SMS Center: Outbox + sửa lỗi font tiếng Việt

### Sửa lỗi font UTF-8

Tin nhắn nhà mạng VN (VINAPHONE / VNPT / VIETTEL) đang hiển thị `�` cho các ký tự 2-byte UTF-8 (à, ò, À) trong khi 3-byte (ặ, ề) hiển thị bình thường. Nguyên nhân: locale POSIX/C khiến shell xử lý `sms_tool recv -j` output như Latin-1 ở một số tin nhắn.

Fix layered:

- **`scripts/usr/lib/qmanager/cgi_base.sh`** — `Content-Type: application/json; charset=utf-8` (defensive)
- **`scripts/www/cgi-bin/quecmanager/cellular/sms.sh`** — `export LC_ALL=C.UTF-8` ở đầu script; nếu raw output không phải UTF-8 hợp lệ → re-decode từ Windows-1252 (siêu tập Latin-1) sang UTF-8 qua iconv

### Outbox (tin nhắn đã gửi)

Mới — lưu vào file JSON cục bộ `/usrdata/qmanager/sent_sms.json`, atomic ghi (tmp + mv), cap 100 entries gần nhất.

Backend `sms.sh`:

- GET `?folder=outbox` → trả về danh sách từ JSON file
- POST `action=send` → ngoài việc gửi qua sms_tool, append entry vào outbox JSON
- POST `action=delete` + `folder=outbox` → xoá entry khỏi JSON (không gọi sms_tool)
- POST `action=delete_all` + `folder=outbox` → reset file về `{"messages":[],"next_id":1}`

Frontend `hooks/use-sms.ts`:

- Refactor: trả về `data` (inbox) + `outbox` riêng biệt, fetch song song
- `sendSms` thành công → refresh **cả** inbox + outbox (outbox ngay, inbox delay 1s cho modem)
- `deleteSms` / `deleteAllSms` nhận thêm `folder` param

Frontend `sms-inbox-card.tsx`:

- Wrap nội dung bằng `<Tabs value=inbox|outbox>` — click tab để chuyển view
- Outbox dùng cột **"Người nhận"** thay vì **"Người gửi"**, không hiển thị badge VN Brand
- Title/description thay đổi theo tab; counter storage chỉ hiển thị cho Inbox
- Delete + Delete All đều truyền folder hiện hành

Toàn bộ string trong SMS Center + Compose Dialog đã dịch sang `smsCenter.*` keys (tab/cột/dialog/toast/aria-label).

## 📊 Internet Quality widget: thêm điểm %

Widget thứ 4 trên top row dashboard giờ hiển thị **"82% Trung bình"** thay vì chỉ "Trung bình". Điểm số được tính từ `avgLatency` theo bậc tier:

- ≤30ms → 100%→90% (excellent)
- 30→60ms → 90%→75% (good)
- 60→100ms → 75%→50% (fair)
- >100ms → 50%→0% (poor, clamp tại latency 300ms)

Layout: `text-2xl` cho %, `text-4xl` cho tier name, đặt cạnh nhau ở giữa card với `items-baseline`. Trạng thái `offline` / `none` (no data) KHÔNG hiển thị %.

Tooltip detail cũng bổ sung điểm %: `Điểm chất lượng 82% · trung bình 82 ms · loss 0.0% · 45 samples`.

## 📦 Files changed

**Tạo mới (1):**
- `components/theme-toggle.tsx` — dropdown 3 lựa chọn Light/Dark/System

**Xoá (1):**
- `components/donate-dialog.tsx` — nội dung được dời vào card Donate trên trang Support

**Modified (20):**
- `package.json` — bump version v0.5.0-vn
- `lib/i18n/en.json` + `lib/i18n/vi.json` — 9 namespace mới + sửa cellScanner/neighbouringCells + xoá sidebar.donate
- `components/app-sidebar.tsx` — gắn ThemeToggle, gỡ DonateDialog wiring
- `components/nav-user.tsx` — bỏ Toggle Theme + dịch toàn bộ
- `components/support/support.tsx` — grid 3 cột + card Donate inline
- `components/cellular/cell-scanner/cell-scanner.tsx` + `neighbourcell/neighbourcell.tsx`
- `components/about-device/about-device.tsx` + `about-qmanager-card.tsx` + `device-information-card.tsx`
- `components/dashboard/rat-primary-card.tsx` + `recent-activities.tsx` + `device-metrics.tsx`
- `components/dashboard/internet-quality-widget.tsx` — `latencyToScore()` + render %
- `components/cellular/cell-data.tsx` + `cellular/band-locking/band-settings.tsx`
- `components/cellular/sms/sms-center.tsx` + `sms-inbox-card.tsx` (Tabs Inbox/Outbox) + `sms-compose-dialog.tsx`
- `hooks/use-sms.ts` — outbox support
- `scripts/usr/lib/qmanager/cgi_base.sh` — charset=utf-8 header
- `scripts/www/cgi-bin/quecmanager/cellular/sms.sh` — UTF-8 sanitize + outbox endpoint

## 📥 Cập nhật

OTA từ WebUI: **Cài đặt hệ thống → Cập nhật phần mềm → Tải về → Cài đặt**.

Sau cài lại:

- Sidebar header: 2 icon nhỏ cạnh nhau — cờ (ngôn ngữ) + mặt trời/trăng (giao diện)
- Menu User: không còn "Toggle Theme"
- Trang Support: 3 card (Liên hệ / Cộng đồng / Ủng hộ dự án)
- Sidebar: không còn entry "Ủng hộ dự án"
- Trang SMS: tabs **Hộp thư đến** / **Hộp thư đã gửi**
- Widget Chất lượng Internet: hiển thị điểm % cạnh tier name

## 🔬 Validate trên thiết bị (khuyến nghị)

UTF-8 fix cho SMS cần verify trên modem thật:

```sh
ssh root@<modem>
sms_tool -d /dev/smd11 recv -j | xxd | head -40
```

Quan sát bytes của ký tự Việt: nếu thấy `C3 A0` đứng cạnh nhau thì input đã là UTF-8 hợp lệ; nếu thấy `E0` đứng một mình thì là Latin-1 — iconv fallback sẽ kích hoạt. Sau khi deploy v0.5.0-vn, mở lại trang `/cellular/sms` và xác nhận chữ "Vào" / "Còn" / "NGÀY" hiển thị bình thường.

## 🙏 Credit

Upstream [dr-dolomite/QManager-RM520N](https://github.com/dr-dolomite/QManager-RM520N).
**License:** MIT + Commons Clause.
