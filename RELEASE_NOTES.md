# QManager-VN v0.3.2-vn — Autolock fix + UX polish

User feedback v0.3.1-vn: Auto cell-lock daemon "không chạy" sau update, Network Status font nhỏ hơn 3 widget khác, 4G/5G card không có quality tier label, Signal Quality Monitor không thực sự hữu ích bằng Autolock control.

## 🐛 Bug fix quan trọng — Auto cell-lock daemon

**Triệu chứng:** Bật toggle ON ở UI nhưng daemon stay inactive sau restart.

**Nguyên nhân:** CGI dùng `sudo -n systemctl enable qmanager-autolock` để gắn boot-persistence. **RM520N-GL's minimal systemd silently ignores `systemctl enable`** ([platform.sh:47](https://github.com/tuanlongsav/QManager-VN/blob/v0.3.2-vn/scripts/usr/lib/qmanager/platform.sh#L47), [install_rm520n.sh:1594](https://github.com/tuanlongsav/QManager-VN/blob/v0.3.2-vn/scripts/install_rm520n.sh#L1594)). Daemon never got the wants/ symlink → systemd skipped auto-start.

**Fix ([F.2.G](https://github.com/tuanlongsav/QManager-VN/commit/0)):** Use direct symlink pattern (same as upstream install_rm520n.sh):
```sh
# Enable: ln -sf /lib/systemd/system/qmanager-autolock.service \
#                /lib/systemd/system/multi-user.target.wants/qmanager-autolock.service
# Then: systemctl restart qmanager-autolock
# Disable: rm -f wants symlink, systemctl stop
```

Sudoers wildcard rules (line 5, 8-9) đã cover ln/rm/start/stop — chỉ cần CGI gọi đúng commands.

## ✨ Dashboard improvements

### Network Status compact — font lớn hơn
- Public IPv4 + uptime line: từ `text-xs` → `text-sm font-semibold`
- Globe icon `size-3` → `size-4`
- Same hierarchy với "Temperature" / "avg N ms" labels của 3 widget khác

### 4G + 5G Primary Status — đồng nhất layout + quality tiers
- Cả 2 card cùng thứ tự rows: **Band → Channel (EARFCN/ARFCN) → PCI → RSRP → RSRQ → SINR → [RAT-specific row 7]**
- Row 7: 4G = RSSI, 5G = SCS (NR không có RSSI per Quectel AT spec)
- **Quality tier badge** (Best / Good / Fair / Poor) cạnh value của RSRP / RSRQ / SINR / RSSI
- Reuse `getQualityLabel` từ `signal-card-utils.ts`
- New `RSSI_THRESHOLDS` (-65/-75/-85/-120 dBm tiers per Quectel field data)
- Label "Excellent" → "Best" (ngắn hơn, vừa inline với value)

### Auto cell-lock card lên Dashboard
- Replace **Signal Quality Monitor** trong Signal Status section bằng **AutolockCard**
- User trực tiếp bật/tắt + xem state machine indicator (idle/watching/locked/signal-lost) trên Home tab
- Gỡ AutolockCard khỏi `/cellular/cell-locking/tower-locking` page (tránh duplicate)
- Delete `components/dashboard/signal-quality-monitor.tsx` (per-row tiers trong 4G/5G card đã cover quality view)

## 📁 Files changed

**Modified (7):**
- `scripts/www/cgi-bin/quecmanager/cellular/autolock.sh` — symlink-based enable/disable
- `scripts/etc/sudoers.d/qmanager` — gỡ redundant rules (covered by wildcards)
- `components/dashboard/network-status-compact.tsx` — text-sm font-semibold
- `components/dashboard/signal-status-card.tsx` — tier badge cạnh value
- `components/dashboard/signal-card-utils.ts` — new `getQualityLabel`
- `components/dashboard/lte-status.tsx` — uniform order + RSSI threshold
- `components/dashboard/nr-status.tsx` — uniform order
- `components/dashboard/home-component.tsx` — replace SignalQualityMonitor with AutolockCard
- `components/cellular/tower-locking/tower-locking.tsx` — remove AutolockCard
- `types/modem-status.ts` — add RSSI_THRESHOLDS

**Deleted (1):**
- `components/dashboard/signal-quality-monitor.tsx`

## 📥 Cập nhật

OTA từ WebUI: **System Settings → Software Update → Download → Install**.

```sh
curl -fsSL -o /tmp/qmanager-installer.sh \
  https://github.com/tuanlongsav/QManager-VN/raw/refs/heads/main/qmanager-installer.sh && \
  bash /tmp/qmanager-installer.sh
```

## 🚧 Đang tới — Phase F.3

Bản v0.4.0-vn tiếp theo: **i18n EN/VI + language toggle** (cờ Việt/Anh cạnh user menu) — user feedback #1 from this iteration.

## 🙏 Credit

Upstream [dr-dolomite/QManager-RM520N](https://github.com/dr-dolomite/QManager-RM520N).
**License:** MIT + Commons Clause.
