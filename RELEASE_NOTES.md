# QManager-VN v0.2.0-vn — Phase B → E milestone

Bản tích lũy thay đổi từ v0.1.0-vn (rebrand baseline). Bao gồm Phase B
(cắt feature), Phase C (broad SDXLEMUR compat), Phase D (VN localization),
và Phase E (auto-cell-lock + Simple Mode + Antennas consolidation).

> Update từ v0.1.0-vn: **System Settings → Software Update** → Download → Install.

## ✂️ Cắt tính năng không cần (Phase B)

- Tailscale VPN — route, components, hooks, CGI, systemd, sudoers, installer
- Email Alerts (msmtp/Gmail SMTP) — toàn bộ pipeline + msmtp dependency
- Web Console (ttyd) + AT Terminal — page, ttyd binary, reverse proxy, lighttpd-mod-proxy
- Discord Bot — discord-bot/ folder, build script, systemd, workflows

Kết quả: 78 files xoá. Bundle nhỏ hơn ~20-30%, 4 daemon ít hơn, mod_proxy lighttpd bỏ.

## 🔧 Tương thích broad SDXLEMUR (Phase C)

Hỗ trợ chính thức **họ SDXLEMUR (Qualcomm SDX62)** thay vì single-target RM520N-GL:

- ✅ **Primary tested**: RM520N-GLAA, RM520N-GL
- 🟡 **Best-effort**: RM520N-EU, RM502Q-AE, RM500Q-GL

Auto-detect modem model + firmware ở boot qua `AT+CGMM/CGMR/CGSN`, lưu `/etc/qmanager/hardware.json`. UI hiển thị:
- **Hardware Badge** trên trang About Device (model + tier + firmware tooltip)
- **Dynamic band whitelist** trong band selector (cảnh báo nếu pick band ngoài datasheet)
- **Feature gating** cho MBN profile, antenna, NR5G SA
- **Unsupported Model Banner** (dismissible) cho best-effort tiers

Doc mới: [`docs/COMPATIBILITY.md`](docs/COMPATIBILITY.md). Issue template `.github/ISSUE_TEMPLATE/compatibility-report.md`.

## 🇻🇳 Tối ưu Việt Nam (Phase D)

- **APN presets VN**: Viettel, Vinaphone, Mobifone, Vietnamobile, Wintel (đẩy lên đầu danh sách)
- **Auto-suggest preset** theo MCC/MNC SIM (mã 452 → match Viettel/Vina/Mobi/etc.)
- **SMS sender display**:
  - Brand sender (VIETTEL/VINAPHONE/MOBIFONE/ngân hàng/Grab…) → uppercase + badge "VN Brand"
  - Phone +84/84 → format local 0xxxxxxxxxx
- 35+ known VN brand list (cả carrier + ngân hàng + service)

## ✨ Tính năng mới (Phase E)

### Auto cell-lock state machine (E.1)
Daemon mới `qmanager-autolock` tự động khóa cell khi tín hiệu ổn định (RSRP > -85, SINR > 5 trong 3 sample), tự động bỏ khóa khi tín hiệu yếu (RSRP < -110 trong 3 sample). Toggle + tune threshold tại **Cellular → Tower Locking → Auto cell-lock card**. Service gated (off-by-default), state machine indicator realtime.

### Dashboard Simple Mode (E.2)
Toggle trên top-right dashboard:
- **Simple** (default): Network status, Device status, Live latency sparkline — đủ check nhanh
- **Pro**: full dashboard với LTE/NR/SCC detail, device metrics, recent activities, signal history chart

Persist trong localStorage; cross-tab sync.

### Antennas consolidation (E.3)
Gộp `cellular/antenna-statistics` + `cellular/antenna-alignment` thành 1 route `cellular/antennas` với 2 tab (URL `?tab=stats|alignment`). Routes cũ vẫn truy cập được cho bookmark cũ.

## 📥 Cài đặt mới

```sh
curl -fsSL -o /tmp/qmanager-installer.sh \
  https://github.com/tuanlongsav/QManager-VN/raw/refs/heads/main/qmanager-installer.sh && \
  bash /tmp/qmanager-installer.sh
```

## 🙏 Credit

Upstream [dr-dolomite/QManager-RM520N](https://github.com/dr-dolomite/QManager-RM520N) — toàn bộ kiến trúc gốc và phần lớn tính năng. Support [DrDolomite trên GitHub Sponsors](https://github.com/sponsors/dr-dolomite).

VN tweaks port từ [tuanlongsav/quectel-rgmii-toolkit](https://github.com/tuanlongsav/quectel-rgmii-toolkit).

**License:** MIT + Commons Clause (kế thừa upstream).
