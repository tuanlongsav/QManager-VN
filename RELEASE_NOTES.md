# QManager-VN v0.2.3-vn — Fix OTA version stamping

**Sửa bug nghiêm trọng**: mọi bản v0.1.0-vn → v0.2.2-vn đều stamp `/etc/qmanager/VERSION` = `"0.1.0"` thay vì tag thực tế. User cài + cập nhật báo thành công nhưng UI vẫn hiển thị `0.1.0`. **Bản này khắc phục** — OTA upgrade từ bất kỳ bản cũ nào về v0.2.3-vn sẽ stamp đúng version.

## 🐛 Bug chính được sửa

**Triệu chứng:** User cài QManager-VN, UI luôn hiển thị `0.1.0` cho dù tag thực tế là v0.2.0-vn / v0.2.1-vn / v0.2.2-vn. OTA update báo "install + reboot" nhưng sau reboot version vẫn `0.1.0`.

**Nguyên nhân:** [`build.sh:69`](https://github.com/tuanlongsav/QManager-VN/blob/v0.2.3-vn/build.sh#L69) đọc version từ [`package.json`](https://github.com/tuanlongsav/QManager-VN/blob/v0.2.3-vn/package.json) và stamp vào `scripts/install_rm520n.sh:46` (`VERSION="..."`). Nhưng `package.json` của fork chốt ở `"0.1.0"` từ Phase A rebrand và không bump theo tag. Mọi release tarball đều stamp `VERSION="0.1.0"` vào installer. Sau khi modem install, `/etc/qmanager/VERSION` luôn = `"0.1.0"`.

**Fix:**
- `.github/workflows/release.yml` — bước mới "Stamp package.json version from tag" trước Setup Bun. Đọc tag (vd `v0.2.3-vn`), sed thay top-level `"version"` field trong `package.json`. Bun install không bị ảnh hưởng (frozen-lockfile chỉ validate dep versions, không phải version của chính package).
- `package.json` — bump version sang `v0.2.3-vn` cho consistency với dev local.

Sau fix, mỗi release từ v0.2.3-vn trở đi sẽ stamp đúng `VERSION="v0.2.x-vn"` vào installer → `/etc/qmanager/VERSION` đúng → `post_install_check` pass → UI hiển thị đúng version.

## 🔄 Cách phục hồi từ bản 0.1.0 bị kẹt

**Trong WebUI:**
1. System Settings → Software Update → Check for updates
2. Sẽ thấy "Update available: v0.2.3-vn" (semver compare đúng "v0.2.3-vn" > "0.1.0")
3. Click Download → Install
4. Sau reboot, UI hiển thị `v0.2.3-vn` ✓

**Hoặc qua SSH (force re-install):**
```sh
rm -f /etc/qmanager/VERSION    # Force fresh-install path nếu cần
curl -fsSL -o /tmp/qmanager-installer.sh \
  https://github.com/tuanlongsav/QManager-VN/raw/refs/heads/main/qmanager-installer.sh && \
  bash /tmp/qmanager-installer.sh
```

## ✅ Bao gồm các fix trước

Bản này tích lũy mọi fix từ v0.1.0-vn → v0.2.2-vn:

- **Phase B**: Cắt Tailscale / Email Alerts / Web Console / AT Terminal / Discord Bot
- **Phase C**: SDXLEMUR broad compat + hardware auto-detect + feature gating + UnsupportedModelBanner
- **Phase D**: VN APN presets (Viettel/Vinaphone/Mobifone/Vietnamobile/Wintel) + auto-suggest by IMSI + SMS brand decode + phone normalize
- **Phase E.1**: Auto cell-lock state machine daemon
- **Phase E.2**: Dashboard Simple Mode vs Pro Mode toggle
- **Phase E.3**: Antennas tabbed consolidation (statistics + alignment)
- **v0.2.1**: Entware bootstrap `/opt` mount point fix
- **v0.2.2**: React `setState` in render → `useEffect`; atomic config write trong autolock CGI; defensive AT response parser

## 📥 Cài đặt

```sh
curl -fsSL -o /tmp/qmanager-installer.sh \
  https://github.com/tuanlongsav/QManager-VN/raw/refs/heads/main/qmanager-installer.sh && \
  bash /tmp/qmanager-installer.sh
```

## 🙏 Credit

Upstream [dr-dolomite/QManager-RM520N](https://github.com/dr-dolomite/QManager-RM520N). Support [DrDolomite trên GitHub Sponsors](https://github.com/sponsors/dr-dolomite).

**License:** MIT + Commons Clause.
