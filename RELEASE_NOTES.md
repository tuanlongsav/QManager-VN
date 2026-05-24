# QManager-VN v0.5.2-vn — Hotfix SMS Việt: bypass sms_tool bằng AT+CMGL UCS-2

User báo v0.5.1 vẫn còn lỗi `�`. Dump byte qua `od -tx1` từ device cho thấy:

```
0046  56 ef bf bd 6f 20 4d 79 20 56 4e 50 54   → V�o My VNPT
```

`ef bf bd` chính là UTF-8 encoding của **U+FFFD** (ký tự thay thế). Stream từ `sms_tool` đã hợp lệ UTF-8 nhưng chứa sẵn ký tự thay thế — dữ liệu gốc đã mất ngay trong `sms_tool`. Frontend walker ở v0.5.1 vô tác dụng.

## Root cause

`sms_tool` (build trên RM520N) có bug trong decoder UCS-2 → UTF-8: code point **U+0080–U+00FF** (precomposed Latin-1: à á â ã è é ê ì í ò ó ô õ ù ú ý + chữ hoa tương ứng) bị thay bằng `U+FFFD`. Code point khác (ặ U+1EB7, đ U+0111, ề U+1EC1...) decode bình thường. `sms_tool -h` không có flag charset/raw để workaround.

## Fix

Bypass content decoder của sms_tool bằng `AT+CMGL` ở chế độ UCS-2:

1. Backend vẫn dùng `sms_tool recv -j` để lấy **structure** (indexes, sender, timestamp, multi-part grouping — các phần này decode đúng).
2. Sau đó gọi `AT+CMGF=1; AT+CSCS="UCS2"; AT+CMGL="ALL"` để lấy **raw UCS-2 hex** từng storage slot.
3. Parse CMGL output qua awk thành map `{ "idx": "hex_string", ... }`.
4. Với mỗi merged message, join hex của tất cả indexes → field mới `content_hex`.
5. Restore `AT+CMGF=0` để các consumer khác không bị ảnh hưởng.
6. Frontend (`lib/decode-ucs2.ts`) decode `content_hex` thành JS string và overwrite field `content`.

Test trên device:
```
hex 005600E0006F = V + à (U+00E0) + o = "Vào" ✓
hex 00C10070 = Á + p = "Áp" ✓
hex 00FD = ý ✓
hex 00F2 = ò ✓
```

## 📦 Files changed

**Tạo mới (1):**
- `lib/decode-ucs2.ts` — `decodeUcs2Hex(hex)` parser BMP UCS-2 hex → JS string

**Xoá (1):**
- `lib/fix-mixed-utf8.ts` — fix sai hướng ở v0.5.1, không còn dùng

**Modified (4):**
- `package.json` + `README.md` — bump v0.5.2-vn
- `types/sms.ts` — thêm `content_hex?: string` field
- `hooks/use-sms.ts` — decode `content_hex` overwrite `content` cho inbox
- `scripts/www/cgi-bin/quecmanager/cellular/sms.sh` — fetch UCS-2 hex qua AT+CMGL, parse awk thành map, attach `content_hex` mỗi message; restore PDU mode sau khi xong

## 📥 Cập nhật

OTA: **Cài đặt hệ thống → Cập nhật phần mềm → Tải về → Cài đặt**.

Sau cài + hard-refresh browser (Cmd/Ctrl+Shift+R), mở `/cellular/sms`:

- Tin nhắn VNPT: "Nạp tiền tặng 50% - **Vào** My VNPT ngay! **Áp** dụng duy nhất khi Qu**ý** kh**á**ch..." (các chữ in đậm trước đây là `�`)
- Tin VNPT Money: "**Còn** 2 NG**À**Y CU**Ố**I để nộp lệ ph**í** x**é**t tuy**ể**n ĐH-CĐ..."

## 🔬 Nếu vẫn lỗi

SSH vào modem, kiểm tra mode AT đã đúng:

```sh
qcmd 'AT+CMGF=1' && qcmd 'AT+CSCS="UCS2"' && qcmd 'AT+CMGL="ALL"' | head -10
```

Output phải có dòng hex (không phải `+CMS ERROR`). Sau đó:

```sh
curl -s -u admin:<password> https://<modem-ip>/cgi-bin/quecmanager/cellular/sms.sh \
    | jq '.messages[0] | {sender, content, content_hex: (.content_hex // "" | .[:60])}'
```

`content_hex` phải có giá trị bắt đầu bằng `0028` (= "(") hoặc tương tự — không rỗng.

## 🙏 Credit

Upstream [dr-dolomite/QManager-RM520N](https://github.com/dr-dolomite/QManager-RM520N).
**License:** MIT + Commons Clause.
