# HomePod Restore

A friendly Mac app for USB-restoring 1st-gen HomePods (A1639, `AudioAccessory1,1`), built on the
[homepod-restore guide](https://github.com/UnbendableStraw/homepod-restore) and the tools from
tihmstar, David Ryskalczyk (d235j), 0x7ff and libimobiledevice.

## What it does

- **Restore**: plug in a HomePod (upside down → adapter → USB → power) and it appears as a card.
  One click runs `gaster pwn` → `gaster reset` → `idevicerestore -d -e -y -i <ECID> -C <cache> <ipsw>`
  and shows plain-English steps with a progress bar instead of a wall of log lines.
- **Several HomePods at once**: each card is one USB port. Jobs target their HomePod by ECID, the
  checkm8 step is serialized, and the root filesystem is unpacked once into a shared cache so
  parallel `idevicerestore` runs never race on extraction. "Restore automatically when plugged in"
  turns it into a batch station (it won't re-restore the same HomePod after it finishes).
- **Firmware**: downloads the prebuilt 18.3 IPSW from nicsfix.com (resumable, SHA-256 checked),
  imports any `.ipsw` you have, and shows Apple's current signing status from ipsw.me.
- **Build your own**: lists full HomePod OTAs from ipsw.me (largest per build, betas hidden), pairs
  each with the matching Apple TV HD (AppleTV5,3) IPSW, downloads the OTA, `makeipsw.sh` and
  `firmware_keys.zip`, and pulls **only** `BuildManifest.plist` + the restore ramdisk out of the
  ~5 GB Apple TV IPSW with HTTP range requests (~80 MB). Then runs makeipsw.sh as admin.
- **Health check**: Quick check (USB link speed, A8 chip, b238 board, checkm8 unlock) and a
  non-destructive Boot test (`idevicerestore -z`: boots the restore ramdisk, erases nothing).
  NAND is judged during a real restore (NAND wait time, "Waiting on NAND", NVRAM timeouts, Disk Failure).
- **Color change (Space Gray ↔ White)**: over the factory DIAGS serial shell, *Reconfigure Model…*
  rewrites the three SysCfg keys that carry a HomePod's color — `Mod#` (model number), `CLCG`
  (Cover Glass Color) and `CLHS` (Housing Color) — and reads all three back. Confirmed on real
  hardware: after restoring firmware, the iOS setup prompt shows the new color. See
  [docs/diags-boot.md](docs/diags-boot.md#color-reconfiguration-space-gray--white).
- **Errors explained**: every message in the guide's Troubleshooting section is mapped to a
  title, explanation and "what to try", with hardware failures flagged as such. "Copy support info"
  produces a Discord-ready report (ECID redacted).
- Links to the Discord, PayPal donations, the guide, and credits for tihmstar and David.

## Building

Needs macOS 13+ and Xcode or the Command Line Tools.

```bash
./scripts/build-app.sh                  # → dist/HomePod Restore.app + zip
BUNDLE_TOOLS=1 ./scripts/build-app.sh   # also ships gaster/idevicerestore/irecovery inside the app
swift test                              # core unit tests
HOMEPOD_FAKE_TOOLS=1 swift test         # + end-to-end job tests with fake gaster/idevicerestore
HOMEPOD_NET_TESTS=1 swift test          # + live partial-zip read of Apple's Apple TV IPSW
```

`BUNDLE_TOOLS=1` needs the tools installed on the build Mac (guide steps or Setup → Install) and
`brew install dylibbundler`. Bundled tools are for the build Mac's CPU (`Resources/bin/ARCHS`);
on other CPUs the app falls back to installed tools. With bundled tools, end users don't need
Homebrew at all to restore.

Without bundled tools, Setup opens `scripts/setup-tools.sh` in Terminal. It follows the guide
(d235j tap, HEAD libs, idevicerestore @ d2e1c4f with the irecv_init fix, removes the tap's
idevicerestore) and builds gaster with `scripts/patches/gaster-ecid.patch` into
`~/Library/Application Support/HomePod Restore/bin`.

The app is ad-hoc signed by default; downloaded copies need right-click → Open the first time.
Set `SIGN_ID` to a Developer ID and notarize for a smooth first launch.

## gaster patch

Stock gaster opens the first DFU device it finds. The patch adds `GASTER_ECID=0x…`: only the DFU
device whose serial string has that ECID is used (for `pwn`, `reset`, everything). Without it the
app still works, but only one HomePod may be in DFU mode at a time.

## Remote manifest

Upload `Distribution/manifest.json` to `https://nicsfix.com/ipsw/manifest.json` to change the
recommended firmware, add a warning note, show an announcement banner, or change the Discord /
donate links — no app update needed. If it's missing, the app uses the built-in 18.3 entry.

## Files

- Logs: `~/Library/Logs/HomePod Restore/`
- Firmware: `~/Library/Application Support/HomePod Restore/Firmware/`
- Shared restore cache (unpacked rootfs, ~3.3 GB): `…/HomePod Restore/RestoreCache/`
- Build work dir (no spaces, makeipsw.sh doesn't quote paths): `~/Library/Caches/HomePodRestore/build/`

## Layout

```
Sources/HomePodRestoreCore/   Foundation-only logic (builds & tests on Linux too)
  RestoreJob.swift            gaster + idevicerestore orchestration, unlock serialization
  RestoreProgress.swift       log → phases / progress / hardware info
  ErrorCatalog.swift          known messages → plain-English diagnoses
  FirmwareCatalog.swift       ipsw.me + nicsfix.com manifest
  FirmwareLibrary.swift       local IPSWs, BuildManifest inspection, shared rootfs cache
  IPSWBuilder.swift           makeipsw.sh pipeline, partial donor download
  ZipArchive.swift            ZIP/ZIP64 reader over files or HTTP ranges, verbatim entry copier
  Downloader.swift            resumable downloads
Sources/HomePodRestore/       SwiftUI app, IOKit USB monitor
scripts/                      build-app.sh, bundle-tools.sh, setup-tools.sh, gaster patch
Distribution/manifest.json    remote catalog to host on nicsfix.com
```
