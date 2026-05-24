# UPSTREAM_DIFF — Tracking changes from dr-dolomite/QManager-RM520N

Bản ghi các thay đổi của fork QManager-VN so với upstream để khi sync upstream (`git fetch upstream && git merge upstream/main`) biết được điểm conflict cần giải quyết.

## Upstream baseline

- Repo: https://github.com/dr-dolomite/QManager-RM520N
- Branch: `main`
- Cloned at: 2026-05-24 — upstream version `v0.1.12`

## Loại thay đổi

### 🔁 OTA URL rebrand (Phase A)
- `qmanager-installer.sh` — `GITHUB_REPO` (dòng 19) + comment đầu file
- `scripts/www/cgi-bin/quecmanager/system/update.sh` — `GITHUB_REPO` (dòng 30)
- `scripts/usr/bin/qmanager_update` — URL whitelist (dòng 94, 97)
- `scripts/usr/bin/qmanager_auto_update` — `REPO` (dòng 46)
- `docs/DEPLOYMENT.md` — install command URL
- `docs/README.md` — git clone URL
- `docs/BACKEND.md` — URL whitelist doc

### 📝 Brand / documentation rewrite (Phase A)
- `README.md` — viết lại tiếng Việt; bản gốc lưu ở `UPSTREAM_README.md`
- `RELEASE_NOTES.md` — reset cho v0.1.0-vn
- `package.json` — `name`, `version`, `description`, `repository`
- `CLAUDE.md` — thêm section "QManager-VN fork goals"

### 🚀 New infrastructure (Phase A)
- `.github/workflows/release.yml` — auto-build tarball + sha256 + GitHub Release khi push tag `v*`
- `UPSTREAM_DIFF.md` — file này
- `UPSTREAM_README.md` — backup README upstream

### ✂️ Feature cuts (Phase B — chưa apply)
- Tailscale VPN (route, components, hooks, CGI, systemd, installer)
- Email Alerts (msmtp/Gmail SMTP)
- Web Console (ttyd) + AT Terminal
- Discord Bot (`discord-bot/`, `build-discord-bot.sh`, `.github/workflows/discord-release.yml`)

### 🔧 Hardware compat (Phase C — chưa apply)
- Auto-detect smd7 vs smd11 (port từ rgmii-toolkit)
- Auto-detect model + firmware → `/etc/qmanager/hardware.json`
- Dynamic band whitelist per-model (`constants/band-whitelist.ts`)
- Feature gating (`lib/feature-gating.ts`)
- UnsupportedModelBanner cho model best-effort
- `docs/COMPATIBILITY.md` + issue template

### 🇻🇳 VN localization (Phase D — chưa apply)
- SMS brand decode VINAPHONE/VIETTEL/MOBIFONE
- Phone normalize +84/0XXX
- UCS-2 67-char/segment fix
- VN carrier APN presets (Viettel, Vinaphone, Mobifone, Vietnamobile)
- Auto-select preset theo MCC/MNC SIM
- `AT+QNWLOCK="common/5g,..."` quote fix nếu cần

### ✨ New features (Phase E — chưa apply)
- Auto-cell-lock state machine (`qmanager-autolock` daemon)
- Dashboard Simple Mode vs Pro Mode toggle
- Feature consolidation: gộp band/tower/freq-lock, apn/sim-profiles/scenarios, antennas, monitoring, local-network, imei

## Sync upstream workflow

```bash
# Pull upstream changes (read-only)
git fetch upstream main

# Review changes
git log HEAD..upstream/main --oneline

# Merge selectively (cherry-pick) hoặc full merge
git merge upstream/main           # full merge — conflict ở các file đã rebrand
# hoặc:
git cherry-pick <commit-sha>      # pick từng commit

# Conflict resolution checklist:
# - Giữ GITHUB_REPO = tuanlongsav/QManager-VN ở mọi file OTA
# - Giữ README.md tiếng Việt (UPSTREAM_README.md có thể merge từ upstream/main:README.md)
# - Verify URL whitelist trong qmanager_update vẫn trỏ về longht
```
