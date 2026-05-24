---
name: Compatibility report (SDXLEMUR modem)
about: Báo cáo trạng thái QManager-VN trên modem chưa được kiểm chứng
title: "Compatibility report: <model>"
labels: compatibility-report
assignees: ''
---

## Modem info

**Model** (`AT+CGMM`):
```
[Paste output here, e.g. RM502Q-AE]
```

**Firmware** (`AT+CGMR`):
```
[Paste output here, e.g. RM502QAEAR11A03M4G_01.001.01.001]
```

**SoC platform**:
- [ ] SDX62 (SDXLEMUR — RM520N/RM502Q/RM500Q family)
- [ ] SDX65 (RM521F)
- [ ] Khác (xin chỉ rõ):

**Kernel** (`uname -a`):
```
[Paste output here]
```

**Filesystem layout**:
- [ ] `/usrdata` UBIFS persistent partition tồn tại
- [ ] Init system là `systemd` (`pidof systemd > 0`)
- [ ] Có thể remount root RW (`mount -o remount,rw /`)

## QManager-VN install

**Version đã cài**:
```
[e.g. v0.3.0-vn]
```

**Cài thành công?**: yes / no
**Nếu fail, log liên quan**:
```
[Paste relevant snippets from /tmp/qmanager_install.log]
```

## Feature test results

Đánh `[x]` cho pass, `[ ]` cho fail/chưa test, ghi chú nếu cần.

### Core
- [ ] Login web UI hoạt động
- [ ] Hardware badge hiển thị đúng model + tier
- [ ] Dashboard hiển thị RSRP/RSRQ/SINR realtime
- [ ] AT command qua CGI test endpoint trả về phản hồi modem

### Cellular
- [ ] Band locking — LTE: select + apply
- [ ] Band locking — NR SA: select + apply
- [ ] Band locking — NR NSA: select + apply
- [ ] APN management — add/edit/delete
- [ ] Cell scanner (`AT+QSCAN`)
- [ ] Tower lock by PCI
- [ ] IMEI read
- [ ] IMEI modify (cẩn thận — chỉ test trên IMEI bạn sở hữu)
- [ ] FPLMN management
- [ ] MBN profile select

### Network
- [ ] TTL/HL setting
- [ ] MTU configuration
- [ ] IP Passthrough
- [ ] Ethernet status (RTL8125B nếu có)

### SMS
- [ ] Send SMS
- [ ] Receive SMS
- [ ] Multi-part SMS đúng (UCS-2 67 char/segment)
- [ ] VN carrier brand sender (Viettel/Vinaphone/Mobifone) decode đúng

### Monitoring
- [ ] Network latency monitor
- [ ] Network events timeline
- [ ] SMS alerts
- [ ] Watchdog (auto-recovery)

### Antenna (4x4 MIMO)
- [ ] Antenna statistics per-port
- [ ] Antenna alignment 3-position recording

## Behavioral observations

[Bất kỳ điều gì bất thường: lỗi runtime, AT command nào return ERROR, UI render sai…]

## Đề xuất

Bạn muốn QManager-VN làm gì tiếp theo cho model này?
- [ ] Promote tier (`best-effort` → `tested` nếu bạn test đầy đủ)
- [ ] Update band whitelist trong `constants/band-whitelist.ts`
- [ ] Update feature gating trong `lib/feature-gating.ts`
- [ ] Add to compatibility matrix trong `docs/COMPATIBILITY.md`
- [ ] Khác:

---

Cảm ơn bạn đã báo cáo! Maintainer sẽ phản hồi trong vòng 7 ngày.
