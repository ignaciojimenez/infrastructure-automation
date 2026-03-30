# Backup Restore Test Log

Running log of quarterly restore tests. See `BACKUP_AND_RECOVERY.md` for the rotation schedule.

---

## Q2 2026 — UniFi LXC vzdump from USB

**Date:** 2026-03-30
**Source:** USB recovery drive (`/mnt/usb-recovery/current/101/vzdump-lxc-101-2026_03_30-03_03_06.tar.zst`)
**Method:** `pct restore 999` to temporary container on Proxmox (local-zfs storage)

| Step | Result |
|------|--------|
| Mount USB, locate vzdump file | OK — file present, 1.1G |
| `pct restore 999 ... --storage local-zfs --hostname test-unifi-restore --start 0` | OK — extracted 2.8G in ~24s |
| Verify container config (`pct config 999`) | OK — matches production LXC 101 config (cores, memory, network, features) |
| Mount filesystem (`pct mount 999`) | OK |
| Verify UniFi data directory (`/var/lib/unifi/`) | OK — `db/`, `sites/`, `backup/autobackup/`, `system.properties` all present |
| Verify autobackup files | OK — `.unf` files present through 2026-03-29, correct sizes (~8M each) |
| Verify hostname (`/etc/hostname`) | OK — `unifi` |
| Verify UniFi service enabled | OK — `unifi.service` in systemd multi-user target |
| Cleanup (`pct destroy 999`) | OK — container removed cleanly |

**Result: PASS**

**Notes:**
- `--storage local` failed (doesn't support container rootdir) — must use `local-zfs` for LXC restores
- Did not start the container (would conflict with production LXC 101 on same IP). Filesystem inspection was sufficient to validate integrity.
- File permissions and ownership preserved correctly through the rsync → restore chain
- Next test (Q3 2026): Home Assistant curlbin backup — decrypt + inspect contents
