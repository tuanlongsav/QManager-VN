# Compatibility Matrix — SDXLEMUR family

QManager-VN được thiết kế cho modem Quectel dùng platform **SDXLEMUR** (Qualcomm SDX62), nhân Linux 5.4.x ARMv7l, systemd, `/usrdata` UBIFS layout. Tất cả các modem cùng platform chia sẻ chung tập AT command và kiến trúc filesystem — sự khác biệt chủ yếu là **band whitelist** (theo region) và **MBN profile** (theo SKU).

## Trạng thái hỗ trợ

| Modem | SoC | Trạng thái | Ghi chú |
|--|--|--|--|
| **RM520N-GLAA** | SDX62 | ✅ **Primary tested** | Hardware của maintainer ([@tuanlongsav](https://github.com/tuanlongsav)). Tested mỗi release. |
| **RM520N-GL** | SDX62 | ✅ **Tested-by-upstream** | QManager upstream test trên đây — kế thừa từ [dr-dolomite](https://github.com/dr-dolomite). |
| **RM520N-EU** | SDX62 | 🟡 **Best-effort** | Cùng platform, band whitelist EU (xem `constants/band-whitelist.ts`). |
| **RM502Q-AE** | SDX62 | 🟡 **Best-effort** | Cùng SDXLEMUR; band Asia/EU. |
| **RM500Q-GL** | SDX62 | 🟡 **Best-effort** | 5G Sub-6 Stage 1, NSA-only trên firmware cũ. |
| **RM521F-GL** | SDX65 | ❌ **Out of scope** | SoC khác (X65 không phải SDXLEMUR); engineering sample-only. |
| **RM551E-GL** | SDX72 | ❌ **Out of scope** | OpenWRT chạy trên host khác (không phải vanilla Linux trên modem). |

### Định nghĩa tier

- **Primary tested** — Hardware maintainer dùng hàng ngày. Mọi release đều test trước khi push tag. Bug được fix nhanh nhất.
- **Tested-by-upstream** — Test ở upstream [dr-dolomite/QManager-RM520N](https://github.com/dr-dolomite/QManager-RM520N) hoặc community report đầy đủ. Mức tin cậy cao.
- **Best-effort** — Cùng platform SDXLEMUR nên kiến trúc tương thích, nhưng chưa có hardware để test trực tiếp. Các tính năng cốt lõi (signal monitoring, AT command, band lock) khả năng cao work. Các tính năng region-specific (band whitelist, MBN profile) có thể cần điều chỉnh. **Cần community report.**
- **Out of scope** — Kiến trúc khác đủ xa để không hỗ trợ trong fork này.

## Auto-detection

Khi QManager-VN khởi động lần đầu trên modem, `qmanager-poller` chạy `detect_hardware()` (từ `scripts/usr/lib/qmanager/detect_hardware.sh`) một lần để probe:

- `AT+CGMM` → model (e.g. `RM520N-GLAA`)
- `AT+CGMR` → firmware (e.g. `RM520NGLAAR01A08M4G_01.206.01.206`)
- `AT+CGSN` → IMEI

Kết quả lưu vào `/etc/qmanager/hardware.json` và UI đọc qua CGI `system/hardware-info.sh`. Đây là single source of truth cho:

- **Hardware badge** trên trang About Device và footer dashboard
- **Dynamic band whitelist** trong band selector (cảnh báo nếu user chọn band ngoài datasheet)
- **Feature gating** cho MBN profile, antenna alignment, NR5G SA
- **Unsupported model banner** nếu tier là `best-effort` hoặc `unsupported`

Để force re-detect (sau khi flash firmware mới):

```sh
rm /etc/qmanager/hardware.json && systemctl restart qmanager-poller
```

## Báo cáo trạng thái trên modem khác

Nếu bạn đang chạy QManager-VN trên model thuộc tier **best-effort** hoặc **out of scope**, hãy mở [GitHub Issue](https://github.com/tuanlongsav/QManager-VN/issues/new?template=compatibility-report.md) báo cáo:

1. Output `AT+CGMM` và `AT+CGMR` (model + firmware exact)
2. Cấu trúc filesystem có giống RM520N không (kernel version, `/usrdata` UBIFS, systemd vs procd)
3. Test mỗi nhóm tính năng và đánh dấu pass/fail:
   - Signal monitoring (RSRP/RSRQ/SINR/SNR realtime)
   - SMS center (gửi/nhận)
   - Band locking (LTE + NR SA + NR NSA)
   - APN management
   - Cell scanner (`AT+QSCAN`)
   - Tower lock
   - IMEI read/modify
   - MBN profile select (nếu có)
   - Antenna alignment + statistics (4x4 MIMO)

Issue template `.github/ISSUE_TEMPLATE/compatibility-report.md` có form sẵn để fill.

## Cập nhật matrix

Khi có community report mới, maintainer sẽ:
1. Cập nhật table ở đầu file này
2. Cập nhật `constants/band-whitelist.ts` nếu cần thêm band entry cho model mới
3. Cập nhật `lib/feature-gating.ts` nếu cần loại trừ feature cho model mới
4. Tag release `v0.x.y-vn` với changelog "Compatibility: X added/promoted"

PR welcome — fork repo, sửa table này + add band whitelist entry, mở PR ngược về `main`.
