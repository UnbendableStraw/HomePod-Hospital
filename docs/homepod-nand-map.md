# HomePod (AudioAccessory1,1 / A8) NAND map — observed from the SSH ramdisk

Observed on a live pod (ECID …000001) over the d235j homepod ssh-ramdisk.
Read raw devices with `dd bs=1m` (512-byte reads return nothing — needs large
aligned blocks).

| device | IOMedia name | size | contents |
|--------|--------------|------|----------|
| disk0 | `Apple NAND Media` | 16,000,000,000 B (3,906,250 × 4 KiB) | the user area: GPT on 4 KiB sectors, one partition (disk0s1, LBA 6–3,906,244, "Container") holding the APFS container; no free space |
| disk1 | (APFS container) | 15,999,954,944 B | disk1s1 System, disk1s2 Data (encrypted), disk1s3 Hardware, disk1s4 Preboot, disk1s5 Update — not SysCfg |
| disk2 | `Apple Firmware Media` | 4 MiB | **Firmware**: iBoot and DeviceTree img4s (the `Util_Find_SysCfg` / `Find_Fast_Scan` strings and the BNCH/BORD nonce tags are iBoot's) |
| disk3 | `Apple LLB Media` | 1,036,288 B | **LLB** img4 (`illb`) |
| disk4 | `Apple PanicLog Media` | 1 MiB | **panic log** (empty on a pod that hasn't panicked: reads return nothing or errors) |

Numbers from a full `ioreg` of the live pod (`~/homepod/SSHRD_Script/ioreg_full.txt`).
**BSD disk numbers are not fixed** — an earlier version of this table had disk3 as the panic
log, which was really the LLB. Always find a region by its IOMedia name (the app does:
`DiagnosticsController.detectPanicDevice`, `hpdiag-partmap`).

The NAND (a Toshiba PPN, 16 GB) sits behind the A8's ANS storage controller, which runs
Apple's FTL firmware. Besides the user area it keeps several fixed areas of its own, each with
its own read and write command; the four devices above are the ones iOS exposes as disks.
The others are reached through separate drivers: SysCfg (`ASPDiagnostic` →
`AppleDiagnosticDataAccessReadOnly`), NVRAM (`ASPNVRAM`), effaceable storage
(`AppleEffaceableBlockDevice`: **960 bytes usable**, one 4 KiB unit holding four 1 KiB copies),
and controller-internal tables. Under Nicotine (Linux) HoolockLinux's `apple-asp` driver shows
all of them: `asp0n1` user area (read-write), `asp0n2` LLB, `asp0n3` Firmware, `asp0n4` UTILDM,
`asp0n5` DM, `asp0n6` CTRLBITS, `asp0n7` effaceable, `asp0n8` NVRAM, `asp0n9` SysCfg,
`asp0n10` panic log (all but `asp0n1` read-only).

The ProtoPod dumps follow the same split: `rdisk0` user area, `rdisk1` the APFS container,
`rdisk2` Firmware, `rdisk3` LLB.

## SysCfg status — READ CONFIRMED
- **Read path proven.** SysCfg is exposed live via the IORegistry property
  `AppleDiagnosticDataSysCfg` on `AppleDiagnosticDataAccessReadOnly`
  (`ioreg -r -c AppleDiagnosticDataAccessReadOnly -l`). The real capture is
  131072 bytes, signature `gfCS`. The app's reversed-key parser carves it to:
  Serial SERIAL000001, Wi-Fi 02:aa:bb:cc:dd:01, BT …:02, Eth …:03,
  Model MQHW2, Region LL/A, RModel A1639 — validated against the on-device dump.
- Write path: plumbing is **ready and safe** (write → read back → byte-compare,
  refuse on mismatch), but **gated** — it refuses until the on-device *sink* (how
  the ramdisk writes SysCfg back to NAND) is validated. The read-only write-probe
  (bundled into Pull diagnostics; `SSHRamdiskTransport.writeProbeCommand`)
  enumerates candidates (`AppleNANDConfigAccess` node, CLIs) so the sink can be
  pinned without guessing. Candidate: symmetric to the read via `AppleNANDConfigAccess`.
- SysCfg is not in any of disk0–disk4. It is one of the storage controller's own areas
  (the "semi-hidden nand partition" tihmstar described), outside the user area, so no
  `dd` of a BSD disk reaches it. The kernel reads it through `ASPDiagnostic`; Nicotine can
  read it as `/dev/asp0n9`.
- It is not an effaceable locker either: the effaceable area holds only 960 bytes.
- The data block starts with the reversed `gfCS` magic, as Reviv expects (the ioreg capture
  starts with it); the container magic in code is `SysCfg` (forward).

## Diagnostics feature — IMPLEMENTED
Read-only "Pull diagnostics (panic log)" in the Check-health menu:
boot ssh-ramdisk → find `Apple PanicLog Media` by IOMedia name (disk4 on the captured pod)
→ `dd` it with `bs=1m` (panic log) + `ioreg -l` snapshot →
save to a folder the tech picks (paniclog.bin, ioreg.txt, notes.txt). No writes,
no brick risk. Shares the booter with SysCfg read (DiagnosticsController).

## SSH-ramdisk boot modes (app)
The SysCfg + diagnostics flows pick a RamdiskBooter by `syscfgBootMode`:
- **preBooted** — tech booted the pod via SSHRD; app connects + auto-forwards
  iproxy. Works today.
- **sshrd** — app drives the proven d235j boot sequence natively
  (gaster pwn/reset → irecovery -f iBSS/iBEC/logo/ramdisk/devicetree/trustcache/
  kernelcache → bootx) from a built SSHRD `sshramdisk/` (SSHRDLayout, default
  `~/SSHRD_Script`). The "no terminal" goal; needs the ramdisk built once.
- **legacy** — old in-app gaster+ra1nsn0w path; kept only as a fallback.
