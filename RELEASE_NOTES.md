# QManager-VN v1.0.4-vn — Frontend hardening & bug fixes

Bản vá tập trung vào các lỗi frontend phát hiện qua code review: validation thiếu, auth edge-case, và OTA install có thể treo im lặng.

## Lỗi đã sửa

### SMS
- Chặn gửi tin nhắn vượt giới hạn ký tự (GSM 160 / UCS-2 70) — trước đây chỉ cảnh báo mà vẫn cho submit.

### IMEI
- Ghi IMEI chính và backup IMEI yêu cầu **Luhn checksum hợp lệ**, không chỉ đủ 15 chữ số.

### Auth & session
- Parse cookie `qm_logged_in` chính xác (không còn `includes()` dễ false-match).
- `AppLayout` redirect login qua `useEffect` + `useSyncExternalStore` (không redirect trong render).
- `useAutoLogout`: lỗi HTTP 5xx từ `check.sh` không còn bị coi là "online".
- Gom `prepareForReboot()` dùng chung cho reboot/OTA.

### OTA / Software Update
- Luồng cài đặt chained (`installVersion`): kiểm tra response `install_staged` — nếu thất bại hiện lỗi thay vì treo ở "Installing…".

### Bảo mật
- Release notes markdown: chặn link `javascript:` / `data:` — chỉ cho phép `http`, `https`, `mailto`.

### Khác
- Avatar upload: giới hạn 500 KB, resize 128px trước khi lưu `localStorage`.
- Bảng ping history: sửa React key trùng khi nhiều entry cùng timestamp.

## File mới

- `lib/session.ts` — cookie helpers + `prepareForReboot()`
- `lib/safe-markdown.tsx` — link sanitizer cho changelog
- `lib/avatar-image.ts` — resize avatar trước khi lưu

## Cập nhật

OTA: **Cài đặt hệ thống → Cập nhật phần mềm → Kiểm tra cập nhật → Tải về → Cài đặt**.

Sau cài + hard-refresh browser (Cmd/Ctrl+Shift+R).

## Credit

Upstream [dr-dolomite/QManager-RM520N](https://github.com/dr-dolomite/QManager-RM520N).
**License:** MIT + Commons Clause.
