# QManager-VN Documentation

> **Fork notice (QManager-VN):** Đây là fork tối giản của [dr-dolomite/QManager-RM520N](https://github.com/dr-dolomite/QManager-RM520N). Một số tính năng đã được CẮT trong fork (xem [`../UPSTREAM_DIFF.md`](../UPSTREAM_DIFF.md)): **Tailscale VPN**, **Email Alerts (msmtp)**, **Web Console (ttyd) + AT Terminal**, **Discord Bot**, **Low Power Mode**. Mã nguồn của chúng đã bị xoá — chỗ nào còn nhắc tới các tên này thì đó là mã *gỡ bỏ* trong installer/uninstaller hoặc mục health-check, không phải tính năng. Tài liệu chi tiết bên dưới vẫn có thể còn nhắc tới chúng như di sản upstream.

QManager-VN là fork web-based GUI quản lý modem Quectel cho họ SDXLEMUR (RM520N-GLAA, RM520N-GL, RM520N-EU, RM502Q-AE, RM500Q-GL). Real-time signal monitoring, cellular configuration, network management.

**Version:** v1.0.6-vn
**License:** MIT + Commons Clause
**Upstream:** [dr-dolomite/QManager-RM520N](https://github.com/dr-dolomite/QManager-RM520N)
**Predecessor:** [SimpleAdmin](https://github.com/dr-dolomite/simpleadmin-mockup)

---

## Documentation Index

| Document | Description |
|----------|-------------|
| [Architecture](ARCHITECTURE.md) | System architecture, data flow, polling tiers, state management |
| [Frontend Guide](FRONTEND.md) | React components, hooks, pages, routing, and UI patterns |
| [Backend Guide](BACKEND.md) | Shell scripts, daemons, systemd units, shared libraries, sudoers grants |
| [API Reference](API-REFERENCE.md) | Complete CGI endpoint reference with request/response schemas |
| [Design System](DESIGN-SYSTEM.md) | Colors, typography, components, theming, and UI conventions |
| [Deployment Guide](DEPLOYMENT.md) | Building the tarball, installing on the modem, OTA updates |
| [RM520N-GL Architecture](rm520n-gl-architecture.md) | Platform internals, AT command transport, boot sequence, troubleshooting |
| [Phase 2: Systemd Migration](rm520n-phase2-systemd-migration.md) | Historical: converting the procd init.d scripts to systemd units |
| [`reference/`](reference/) | Per-feature operational notes (antenna alignment, custom DNS, data counter, SIM profiles, WAN profiles, AT transport, …) — read one only when working on that subsystem |

---

## Quick Start

### Prerequisites

- [Bun](https://bun.sh/) (package manager and runtime)
- A Quectel SDXLEMUR modem. QManager-VN runs **inside** the modem, on its own
  Linux system — there is no separate OpenWRT host.
  - **RM520N-GLAA** — primary target, the hardware this fork is tested on
  - **RM520N-GL / RM520N-EU / RM502Q-AE / RM500Q-GL** — same SoC family

> Upstream's original target was the RM551E-GL behind an OpenWRT host, and older
> docs still describe that arrangement. This fork targets the standalone modem
> only; the work that used to live on a `dev-rm520` branch is now mainline.

### Development

```bash
git clone https://github.com/tuanlongsav/QManager-VN.git
cd QManager-VN
bun install
bun run dev        # Dev server at http://localhost:3000
```

To talk to a real modem from the dev server, uncomment the `rewrites()` block in
`next.config.ts` and point it at your device (`192.168.225.1` by default). It
ships commented out on purpose: a `rewrites()` block is incompatible with the
static export that `bun run build` produces.

### Production Build

```bash
bun run package    # run-all.sh gate → next build → build.sh → qmanager.tar.gz
```

`bun run package` is the gated path and the one to use. It runs the pre-build
checks first (shell syntax, i18n parity, iCloud conflict copies, sudoers
hygiene), then the static export, then packages frontend + backend + bundled
ARMv7 binaries into `qmanager-build/qmanager.tar.gz`.

Install by copying that tarball to the modem and running `install_rm520n.sh`
from inside it — see [Deployment Guide](DEPLOYMENT.md). The frontend lands in
`/usrdata/qmanager/www`, not `/www`.

---

## Tech Stack

| Layer | Technology |
|-------|-----------|
| **Frontend Framework** | Next.js 16 (App Router, static export) |
| **Language** | TypeScript 5, POSIX shell, Rust (ping daemon) |
| **UI Components** | shadcn/ui (Radix UI primitives) |
| **Styling** | Tailwind CSS v4, OKLCH color system |
| **Charts** | Recharts 2.15 |
| **Forms** | React Hook Form + Zod validation |
| **Animations** | Motion (Framer Motion) |
| **Backend** | CGI shell scripts under lighttpd (Entware), run as `www-data` |
| **Shell** | `/bin/sh` is BusyBox ash on the device — write POSIX, not bash |
| **Init** | systemd 244 (`.service` units in `/lib/systemd/system/`) |
| **AT Commands** | `qcmd` wrapper over the bundled `atcli_smd11` binary on `/dev/smd11`, serialized with `flock` |
| **Package Manager** | Bun |

> The installer actively **removes** `socat` / `socat-at-bridge`: they hold
> `/dev/smd11` open and conflict with `atcli_smd11`. Older docs describing a
> socat PTY bridge are describing a setup this fork uninstalls.

---

## Key Features

- **Live Signal Monitoring** — Real-time RSRP, RSRQ, SINR with per-antenna values and historical charts
- **Band & Tower Locking** — Lock specific LTE/NR bands, frequencies, or cell towers (PCI), with signal failover
- **Antenna Alignment** — Guided per-port aiming with live quality readout
- **APN Management** — Create, edit, and switch APN profiles with MNO presets
- **Custom SIM Profiles** — Save and apply multi-step configurations (APN + TTL/HL + Connection Scenario + IMEI), bound to a SIM by ICCID
- **Connection Watchdog** — 4-tier auto-recovery: Re-register to Network, CFUN toggle, SIM failover, reboot
- **Latency Monitoring** — Real-time ping with 24-hour history and aggregated views
- **Cell Scanner** — Active and neighbor cell scanning with frequency calculator
- **Data Usage Counter** — Kernel-sourced counters with per-boot orientation detection
- **Network Settings** — Ethernet link speed, TTL/HL, MTU, custom DNS, IP passthrough
- **System Settings** — unit preferences (temp/distance), timezone, hostname, SSH password, scheduled reboot
- **Scheduled Operations** — Reboot, tower-lock windows and auto-update, armed as systemd timers
- **SMS** — Inbox and sending, with Vietnamese carrier decoding
- **Dark/Light Mode** — Full theme support with OKLCH colors

---

## Project Structure Overview

```
QManager-VN/
├── app/                    # Next.js App Router pages (51 files)
├── components/             # React components (176 .tsx)
│   ├── ui/                 # shadcn/ui primitives (38)
│   ├── cellular/           # Cellular management UI
│   ├── dashboard/          # Home dashboard cards
│   ├── local-network/      # Network settings UI
│   ├── monitoring/         # Monitoring & alerts UI
│   └── system-settings/    # Device and system configuration UI
├── hooks/                  # Custom React hooks (37)
├── types/                  # TypeScript interfaces (18)
├── lib/                    # Utilities + i18n dictionaries (en/vi)
├── constants/              # Static data (MNO presets, event labels)
├── public/                 # Static assets (logo SVG)
├── ping-daemon/            # Rust latency daemon, cross-compiled to ARMv7
├── dependencies/           # Bundled ARMv7 binaries (atcli_smd11, sms_tool, jq, dropbear)
├── scripts/                # Backend (175 files)
│   ├── etc/systemd/system/ # systemd units (16)
│   ├── etc/sudoers.d/      # The privilege boundary for www-data — exact grants, no wildcards
│   ├── usr/bin/            # Daemons, root helpers & utilities (29)
│   ├── usr/lib/qmanager/   # Shared shell libraries (19)
│   ├── www/cgi-bin/        # CGI endpoints (66 scripts)
│   ├── test/               # Harnesses — `bash scripts/test/run-all.sh`, `bun run test:harness`
│   └── dev/                # Dev-machine tooling (iCloud conflict copies, artefact exclusion)
└── docs/                   # This documentation
```

`scripts/etc/init.d/` still holds six procd-era scripts. They are **legacy**:
this platform boots systemd, and the units above are what actually run.

See [Architecture](ARCHITECTURE.md) for detailed diagrams and data flow explanations.
