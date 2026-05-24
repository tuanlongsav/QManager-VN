# QManager-VN v0.1.0-vn — Initial fork release

Bản đầu tiên của QManager-VN — fork tối giản và VN-localized của [dr-dolomite/QManager-RM520N](https://github.com/dr-dolomite/QManager-RM520N).

> Phiên bản này tương đương codebase upstream v0.1.12, đã rebrand OTA về tuanlongsav/QManager-VN, chưa áp dụng feature cuts (Phase B) — sẽ ra mắt ở các bản tiếp theo.

## 🎯 Mục tiêu fork

- **Tối giản, nhẹ, nhanh** — giảm bundle, giảm daemon, giảm route
- **Giữ UI đẹp** — nguyên design language shadcn/Tailwind/OKLCH của upstream
- **VN-localized** — port từ tuanlongsav/quectel-rgmii-toolkit
- **Broad hardware compat** — hỗ trợ họ modem SDXLEMUR (RM520N-GL/GLAA/EU, RM502Q-AE, RM500Q-GL)

## 🔧 Trong bản này

- Rebrand: package name, OTA URLs, GitHub Actions workflow
- README + RELEASE_NOTES tiếng Việt
- Backup `UPSTREAM_README.md` để giữ tài liệu gốc đầy đủ
- OTA URL whitelist trong `qmanager_update` đổi sang `tuanlongsav/QManager-VN`
- Cài đặt qua URL longht's GitHub:
  ```sh
  curl -fsSL -o /tmp/qmanager-installer.sh \
    https://github.com/tuanlongsav/QManager-VN/raw/refs/heads/main/qmanager-installer.sh && \
    bash /tmp/qmanager-installer.sh
  ```

## 📋 Lộ trình

- **v0.2.0-vn** — Phase B: cắt Tailscale, Email Alerts, Web Console, Discord Bot
- **v0.3.0-vn** — Phase C: auto-detect smd7/smd11, hardware compat matrix
- **v0.4.0-vn** — Phase D: SMS Vietnam, VN APN presets
- **v0.5.0-vn** — Phase E: auto-cell-lock, Simple Mode, feature consolidation

## 🙏 Credit

Toàn bộ kiến trúc và phần lớn tính năng thuộc về [dr-dolomite](https://github.com/dr-dolomite). Fork này chỉ là tinh chỉnh cá nhân cho nhu cầu VN.

Nếu thấy QManager hữu ích, support [DrDolomite trên GitHub Sponsors](https://github.com/sponsors/dr-dolomite).

**License:** MIT + Commons Clause (kế thừa upstream)
