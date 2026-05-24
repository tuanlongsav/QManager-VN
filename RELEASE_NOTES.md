# QManager-VN v0.3.3-vn — Dashboard layout overhaul + accordion 4G/5G cards

User feedback v0.3.2-vn: gộp tất cả thông tin cellular về Dashboard, xoá trang riêng Cellular Information, dùng Active Cellular Bands accordion style cho 4G/5G cards, thêm Device Information widget.

## ✨ Dashboard layout mới

### Top row — 5 widget cùng kích thước
| 1 | 2 | 3 | 4 | 5 |
|--|--|--|--|--|
| Network Status | Temperature | SMS | Internet Quality | **Device Info (NEW)** |

- **Device Info widget** mới — card vuông với device-icon.svg (modem image), click mở Dialog chứa toàn bộ Device Information detail (model, manufacturer, firmware, IMEI, phone, IMSI, MIMO, LAN gateway, etc.)

### Row 1 — Signal detail (3 cards, KHÔNG có heading)
| 4G Primary Status | 5G Primary Status | Auto cell-lock |
|--|--|--|

- **4G + 5G Primary Status REFACTORED** dùng Active Cellular Bands accordion style:
  - Mỗi carrier component là 1 AccordionItem với badge tech (PCC/SCC), band name, EARFCN
  - Click expand → hiển thị đầy đủ RSRP/RSRQ/SINR (4G còn RSSI) với progress bars + quality tier (Best/Good/Fair/Poor) + Band Name + UL/DL Frequency + Bandwidth + PCI
  - LTE card filter `technology === "LTE"`, NR card filter `technology === "NR"` — 2 section riêng biệt
  - Default expand first item (PCC), SCCs collapsed
- Bỏ section header "Signal Status" + description (visual noise)

### Row 2 — Information (3 cards)
| Cellular Information | System Health | Recent Activities |
|--|--|--|

- **Cellular Information card** = CellData component (Active SIM, Network Provider, MCCMNC, APN, Network Mode, IP, Serving Cell, Bandwidth, etc.) — di chuyển từ trang riêng đã bị xoá vào Dashboard.

## 🗑️ Removed

- **Cellular and Radio Information** page (`/cellular`) — toàn bộ content giờ ở Dashboard.
- **Antennas** sub-route (`/cellular/antennas`) — vốn chỉ là wrapper tabbed antenna-statistics + antenna-alignment, gỡ luôn.
- Sidebar entry "Cellular Information" + sub-item "Antennas".
- Deprecated components không còn dùng: `lte-status.tsx`, `nr-status.tsx`, `scc-status.tsx`, `signal-status-card.tsx`, `cellular-information.tsx`, `active-bands.tsx`.

> **Note:** Routes `/cellular/antenna-statistics` và `/cellular/antenna-alignment` vẫn truy cập được qua direct URL — chỉ sidebar entry bị xoá vì content đã chuyển sang dashboard.

## 📦 Files changed

**New (2):**
- `components/dashboard/rat-primary-card.tsx` — accordion-style RAT primary card
- `components/dashboard/device-info-widget.tsx` — top-row clickable device widget

**Modified (2):**
- `components/dashboard/home-component.tsx` — 5-widget top row + 2 rows of 3
- `components/app-sidebar.tsx` — gỡ Cellular Information + Antennas entry

**Deleted (8):**
- `app/cellular/page.tsx`
- `app/cellular/antennas/page.tsx`
- `components/dashboard/lte-status.tsx`
- `components/dashboard/nr-status.tsx`
- `components/dashboard/scc-status.tsx`
- `components/dashboard/signal-status-card.tsx`
- `components/cellular/cellular-information.tsx`
- `components/cellular/active-bands.tsx`

## 📥 Cập nhật

OTA từ WebUI: **System Settings → Software Update → Download → Install**.

```sh
curl -fsSL -o /tmp/qmanager-installer.sh \
  https://github.com/tuanlongsav/QManager-VN/raw/refs/heads/main/qmanager-installer.sh && \
  bash /tmp/qmanager-installer.sh
```

## 🚧 Đang tới — Phase F.3

Bản v0.4.0-vn tiếp theo: **i18n EN/VI + language toggle** (cờ Việt/Anh cạnh user menu).

## 🙏 Credit

Upstream [dr-dolomite/QManager-RM520N](https://github.com/dr-dolomite/QManager-RM520N).
**License:** MIT + Commons Clause.
