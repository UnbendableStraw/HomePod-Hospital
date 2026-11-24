# SysCfg over SSH ramdisk — hardware de-risk runbook

Everything in software is built and unit-tested. Much of the boot path is now
also **confirmed from the 2024 HomePod repair chat** (tihmstar / david / Nic) and
coded into `GasterRamdiskBooter`. Do the first run on a **known-good HomePod** —
prove a non-destructive read before trusting the write on a repair unit.

## 0. One-time prerequisites

1. **Tools** — app: Setup → Install tools **(builder)**. Gets `ra1nsn0w`,
   `img4tool`, `tsschecker`, `ldid`, `irecovery`, `iproxy`, and `sshpass`.
2. **SSH overlay** — already assembled into `scripts/ssh-ramdisk-overlay/` from
   SSHRD_Script's `atvssh` (dropbear + `restored_external` launcher, host keys).
   Copy it to `~/Library/Application Support/HomePod Hospital/ssh-ramdisk-overlay/`
   (`…/HomePod Restore/…` on a Mac set up before the app was renamed)
   (or rebuild the app, which bundles it).

## 1. Build the SSH ramdisk (once)

Advanced on → known-good pod in DFU → its card → Check health → **Read SysCfg** →
**Build SSH ramdisk**. It pulls the Apple TV donor ramdisk, injects the overlay
(`img4tool -e` → mount → overlay → `img4tool -c -t rdsk`), and caches
`~/Library/Application Support/HomePod Hospital/SSHRamdisk/sshrd-<build>.img4`.

## 2. What's CONFIRMED (coded) vs. still OPEN

### Confirmed from the chat — now the defaults in `GasterRamdiskBooter`
- **checkm8:** `gaster pwn` → `gaster reset`.
- **APTicket:** `irecovery -q` (NONC/SNON) → `tsschecker -o -m BuildManifest.plist
  -d AudioAccessory1,1 -e <ECID> -N <NONC> -S <SNON> -s ticket.shsh2`. The app
  auto-extracts BuildManifest.plist from the selected HomePod firmware.
- **Boot:** `ra1nsn0w -t ticket.shsh2 -r <ssh-ramdisk.img4> --ipatch-no-force-dfu
  --kpatch-always-get-task-allow --kpatch-codesignature -b "rd=md0 -v
  debug=0x2014e wdt=-1 serial=3"`. **Note:** the restore flow added
  `nand-enable-reformat=1 -restore` — we deliberately DROP those (a read/write of
  SysCfg must not reformat NAND).
- **SSH:** `iproxy 2222 22` → `ssh -p 2222 root@127.0.0.1`, password **`alpine`**
  (driven by `sshpass`). Confirmed working on-pod in the chat.
- HomePod uses the **update** ramdisk; "if there's no NAND, it boots into the ssh
  ramdisk." NAND is reachable on the shell as **`/dev/diskN`** (they used
  `dd if=/dev/disk3`, `cat /dev/disk4`). Disk numbers vary between OS versions; find a
  region by its IOMedia name (`homepod-nand-map.md`).

### Still OPEN — the one thing to pin on the bench
`dumpCommand` / `sinkCommand` in `GasterRamdiskBooter.Config` (default
placeholders `syscfg_dump` / `syscfg_write`). SysCfg is a "semi-hidden nand
partition" (MAC/serial/iCloud data). On the booted shell, investigate:
```
ssh -p 2222 root@127.0.0.1        # password: alpine
ls -la /dev/disk*                  # find the syscfg partition
# candidates to read the raw blob to stdout:
#   dd if=/dev/diskN bs=... count=...        (if syscfg is a block partition)
#   a diag/syscfg tool on the ramdisk, or ioreg AppleDiagnosticDataSysCfg
```
Once you know the command that prints the raw SysCfg blob (and the one that
writes it back), set `dumpCommand`/`sinkCommand` and we're done.

**Tools on the ramdisk.** The 17.5 SSH ramdisk (Apple restore ramdisk + SSHRD
`atvssh` overlay; `/bin/sh` is bash 3.2) has no `base64`, `awk`, `tr`, `sort`,
`od`, `strings`, `timeout` or `/tmp` (only `/private/var/tmp`). The `hpdiag-*`
scripts use only shell builtins plus `sed`, `grep`, `head`, `cut`, `wc`,
`hexdump`, `expr`, `dd`, `ls`, `mount`, `date` and `ioreg`; the app pushes them to
`/private/var/tmp/hpdiag`, stages blobs in `/private/var/tmp`, and binary dumps
come back as `xxd -p` hex. The legacy `base64` paths in `SSHRamdiskTransport`
(the generic `dumpCommand` read with no `sysCfgProperty`, and the `sinkCommand`
write) still cannot work there.

## 3. Prove the read
Read SysCfg on the known-good pod → serial + MACs show → **compare the serial to
the sticker.** Match = read path correct end to end.

## 4. The write is trustworthy by construction
Restore writes the saved dump **verbatim** and reads it back to verify. Repair
loop: Read SysCfg → **Save dump…** on the old chip (or carve with Reviv if dead)
→ swap NAND → **Restore SysCfg from dump…** on the new chip → normal restore.

## Source
Confirmed commands pulled from the 2024 "HomePod repair beta test" chat export
(scripts `..._18.sh` / `..._20.sh` / `..._35.sh` and the ssh-ramdisk logs).
