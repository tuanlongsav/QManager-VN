# QManager-VN v0.5.1-vn — Hotfix: SMS tiếng Việt mixed-encoding repair

User báo sau v0.5.0-vn vẫn còn lỗi font chữ trong tin nhắn SMS từ nhà mạng. Phân tích cho thấy cách `iconv -f WINDOWS-1252` ở backend không xử lý được trường hợp **mixed encoding** — chuỗi tin nhắn vừa chứa byte UTF-8 hợp lệ (3-byte cho `ặ`, `ề`) vừa chứa byte Latin-1 đơn lẻ (1-byte cho `à`, `ò`, `À`). Khi iconv decode toàn bộ stream theo Windows-1252, các byte UTF-8 đúng bị decode lại thành ký tự garbage `áº·`.

## 🐛 Fix mixed UTF-8 ở frontend

Thay vì xử lý ở shell (khó thao tác byte chính xác), tôi viết `lib/fix-mixed-utf8.ts` walk byte-by-byte:

- Byte ASCII (<0x80) → giữ nguyên
- Byte mở đầu chuỗi UTF-8 hợp lệ 2/3/4-byte với continuation đúng → giữ cả chuỗi
- Byte high đứng một mình (stray Latin-1) → re-encode thành 2-byte UTF-8 (`0x80..0xBF` → `C2 + b`; `0xC0..0xFF` → `C3 + (b-0x40)`)

Hook `use-sms.ts` đổi sang dùng `resp.arrayBuffer()` + fixer + `JSON.parse()` để có thể thao tác byte trước khi browser decode UTF-8.

Backend `sms.sh` gỡ bỏ iconv WINDOWS-1252 fallback (giữ `LC_ALL=C.UTF-8` và `Content-Type: application/json; charset=utf-8` vì vẫn cần). Comment giải thích lý do gỡ để tránh người sau vô tình thêm lại.

## 📦 Files changed

**Modified (4):**
- `package.json` — bump v0.5.1-vn
- `lib/fix-mixed-utf8.ts` (mới) — walker repair + `fetchJsonFixed` helper
- `hooks/use-sms.ts` — dùng `fetchJsonFixed`
- `scripts/www/cgi-bin/quecmanager/cellular/sms.sh` — gỡ iconv fallback (kèm comment lý do)

## 📥 Cập nhật

OTA từ WebUI: **Cài đặt hệ thống → Cập nhật phần mềm → Tải về → Cài đặt**.

Sau khi update, mở trang `/cellular/sms` — các ký tự tiếng Việt 2-byte (à, ò, À) phải hiển thị đúng song song với các ký tự 3-byte (ặ, ề) vốn đã đúng.

## 🔬 Nếu vẫn còn lỗi

Hard-refresh browser (Cmd/Ctrl+Shift+R) để force tải lại bundle JS mới. Nếu một số tin cụ thể vẫn lỗi, SSH vào modem và chạy:

```sh
sms_tool -d /dev/smd11 recv -j | jq -r '.msg[].content' | xxd | head -40
```

Gửi output cho dev để phân tích pattern byte.

## 🙏 Credit

Upstream [dr-dolomite/QManager-RM520N](https://github.com/dr-dolomite/QManager-RM520N).
**License:** MIT + Commons Clause.
