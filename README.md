# QManager-VN

<div align="center">
  <img src="public/qmanager-logo.svg" alt="QManager-VN Logo" width="120" />
  <h3>Quectel modem manager — tối giản, VN-localized</h3>
  <p>Fork cá nhân của <a href="https://github.com/dr-dolomite/QManager-RM520N">dr-dolomite/QManager-RM520N</a>, tối ưu cho Việt Nam và mở rộng hỗ trợ họ modem SDXLEMUR (Qualcomm SDX62)</p>

  ![Version](https://img.shields.io/badge/version-v0.5.0--vn-blue?style=flat-square)
  ![License](https://img.shields.io/badge/license-MIT%20%2B%20Commons%20Clause-green?style=flat-square)
  ![Platform](https://img.shields.io/badge/platform-SDXLEMUR-orange?style=flat-square)
  ![Next.js](https://img.shields.io/badge/Next.js-16-black?style=flat-square)
</div>

---

> **Note:** QManager-VN là fork cá nhân của [dr-dolomite/QManager-RM520N](https://github.com/dr-dolomite/QManager-RM520N) (tác giả gốc giữ toàn bộ credit). Fork này tập trung vào: tối giản bundle, gộp tính năng tương tự, port các tinh chỉnh VN từ [tuanlongsav/quectel-rgmii-toolkit](https://github.com/tuanlongsav/quectel-rgmii-toolkit), và mở rộng hỗ trợ broad cho họ modem SDXLEMUR.

---

## Khác biệt so với upstream

**Cắt bỏ:** Tailscale VPN integration, Email Alerts (msmtp/Gmail SMTP), Web Console (ttyd) + AT Terminal, Discord Bot — để giảm bundle, giảm daemon, đơn giản hoá UI.

**Bổ sung (port từ rgmii-toolkit):**
- **SMS Vietnam** — decode brand sender VINAPHONE / VIETTEL / MOBIFONE đúng UCS-2; chuẩn hoá số `+84` / `84` / `0XXX`
- **VN carrier APN presets** — Viettel, Vinaphone, Mobifone, Vietnamobile lên đầu danh sách; auto-select theo MCC/MNC SIM
- **Auto-cell-lock state machine** — lock cell tự động khi signal ổn định (RSRP > −85, SINR > 5), unlock khi mất signal
- **Auto-detect AT device** — `/dev/smd7` chết trên GLAA stock firmware → rewire qua `/dev/smd11`
- **Auto-detect model + firmware** — lưu `/etc/qmanager/hardware.json`, hiển thị badge trong UI
- **Dynamic band whitelist** — band selector theo datasheet model thực tế

**Tổ chức lại UI:**
- **Simple Mode** vs **Pro Mode** toggle — dashboard 4-widget gọn gàng cho user phổ thông, đầy đủ feature cho power user
- **Gộp** các nhóm trang tương tự: Band/Tower/Frequency Lock → 1 trang với 3 tab; APN/SIM Profiles/Scenarios → 1 trang; Antennas Statistics/Alignment → 1 trang; Latency/Network Events/Connectivity → 1 trang; TTL/MTU/IPPT/Ethernet → 1 trang accordion
- Sidebar từ ~35 mục giảm xuống ~18-20 mục

---

## Tương thích phần cứng

| Modem | SoC | Trạng thái |
|--|--|--|
| **RM520N-GLAA** | SDX62 | ✅ Primary tested (hardware của maintainer) |
| **RM520N-GL** | SDX62 | ✅ Tested-by-upstream |
| **RM520N-EU** | SDX62 | 🟡 Best-effort (band list EU) |
| **RM502Q-AE** | SDX62 | 🟡 Best-effort |
| **RM500Q-GL** | SDX62 | 🟡 Best-effort |
| RM521F-GL | SDX65 | ❌ Out of scope (SoC khác) |
| RM551E-GL | SDX72 | ❌ Out of scope (OpenWRT khác kiến trúc) |

Xem [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md) để báo cáo trạng thái trên model best-effort.

---

## Cài đặt nhanh

SSH hoặc ADB vào modem và chạy:

```sh
curl -fsSL -o /tmp/qmanager-installer.sh \
  https://github.com/tuanlongsav/QManager-VN/raw/refs/heads/main/qmanager-installer.sh && \
  bash /tmp/qmanager-installer.sh
```

Nếu modem có `wget` thay vì `curl`:

```sh
wget -O /tmp/qmanager-installer.sh \
  https://github.com/tuanlongsav/QManager-VN/raw/refs/heads/main/qmanager-installer.sh && \
  bash /tmp/qmanager-installer.sh
```

Installer sẽ tự bootstrap Entware, cài lighttpd, deploy frontend + backend, cấu hình systemd, set dropbear SSH password đồng bộ với password web UI. Reboot sau khi cài.

### Cập nhật

Từ phiên bản v0.1.0-vn, vào **System Settings → Software Update** trong WebUI để cài bản mới — không cần SSH. OTA pull tự động từ `tuanlongsav/QManager-VN` GitHub Releases.

### Gỡ cài

```sh
bash /tmp/qmanager_install/uninstall_rm520n.sh
```

Thêm `--purge` để xoá luôn config/profiles. Entware (`/opt/`) luôn được giữ lại.

---

## Tech stack (giữ nguyên upstream)

| Layer | Technology |
|-------|-----------|
| **Frontend** | Next.js 16, React 19, TypeScript 5 |
| **Styling** | Tailwind CSS v4, OKLCH colors, shadcn/ui |
| **Backend** | Shell CGI scripts via lighttpd |
| **AT Transport** | `qcmd` + `atcli_smd11` trên `/dev/smd11` (auto-detect smd7 → smd11) |
| **Init** | systemd |
| **Package Manager** | Bun (dev), Entware opkg (device) |

Xem [UPSTREAM_README.md](UPSTREAM_README.md) để có tài liệu kiến trúc đầy đủ từ upstream.

---

## Phát triển

```bash
git clone https://github.com/tuanlongsav/QManager-VN.git
cd QManager-VN

bun install
bun run dev        # http://localhost:3000

bun run build      # static export to out/
bun run package    # full tarball + SHA-256 cho release
```

---

## Credit

- **[dr-dolomite/QManager-RM520N](https://github.com/dr-dolomite/QManager-RM520N)** — codebase gốc, tác giả [DrDolomite](https://github.com/dr-dolomite). Toàn bộ kiến trúc Next.js + CGI, design system OKLCH/shadcn, và phần lớn tính năng đều thuộc về upstream.
- **[iamromulan/quectel-rgmii-toolkit](https://github.com/iamromulan/quectel-rgmii-toolkit)** — kiến trúc gốc lighttpd + CGI + Alpine, install pipeline, socat-at-bridge.
- **[tuanlongsav/quectel-rgmii-toolkit](https://github.com/tuanlongsav/quectel-rgmii-toolkit)** — source cho các tinh chỉnh VN: SMS brand decode, auto-cell-lock state machine, smd7→smd11 detection.
- **[iamromulan/cellular-modem-wiki](https://github.com/iamromulan/cellular-modem-wiki)** — tài liệu platform SDXLEMUR.

Nếu thấy upstream QManager hữu ích, hãy support [DrDolomite trên GitHub Sponsors](https://github.com/sponsors/dr-dolomite).

---

## License

[MIT + Commons Clause](LICENSE) — kế thừa từ upstream. Fork cá nhân self-hosting hợp lệ. **Không** dùng cho mục đích thương mại hoặc bán dịch vụ dựa trên fork.

Liên hệ thương mại: [DrDolomite](https://github.com/dr-dolomite) (upstream author).

---

<div align="center">
  <p>Fork & maintained by <a href="https://github.com/tuanlongsav">tuanlongsav</a> · Built on the shoulders of <a href="https://github.com/dr-dolomite">DrDolomite</a></p>
</div>
