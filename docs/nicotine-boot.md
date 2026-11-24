# Booting Nicotine (Linux) from HomePod Hospital

**Nicotine** is the Linux system for the 1st-gen HomePod (A1639, `AudioAccessory1,1`, board B238a).
It turns the pod into a standalone AirPlay and Bluetooth speaker with its own web UI, and it also
runs on boards that can no longer run audioOS (dead SEP, dead NAND). HomePod Hospital boots it and
looks after the running pod.

Nicotine is always **tethered**: it is loaded into RAM from DFU through checkm8 and is gone when the
pod loses power. The Mac has to send it over USB again at every power-on. Nothing on the pod's NAND
is written by the boot.

## Booting a pod

1. Build the app (`./scripts/build-app.sh`; it puts the tools and a Nicotine payload inside) and open
   it. Sidebar → **Nicotine (Linux)**.
2. Put the HomePod in DFU: USB adapter on the debug port and its cable in the Mac, HomePod upside
   down, then power. Once it shows up in DFU mode, turn it right-side up. Only one HomePod may be
   connected.
3. First time on this Mac: **Boot loaders** card → **Build release boot loaders**. It takes a minute
   or two, downloads about 1 MB from Apple and writes nothing to the pod.
4. **Boot Nicotine** (the pod is already right-side up). After 30 to 40 seconds it answers at
   `172.16.42.1` over the USB cable and **Open web UI** appears.
5. In the web UI, join WiFi. From Nicotine build 117 the pod keeps its settings on its own flash and
   puts them back by itself at the next boot. The Mac keeps a second copy: it brings it up to date
   after every boot, and **Save settings** does that on demand.

## What the app does

Sidebar → **Nicotine (Linux)** (`Views/NicotineView.swift`), top to bottom:

- **First time? How this works** — a fold-out with the DFU steps, what to expect, and "join WiFi
  in the web UI first".
- **Nicotine payload** — which payload is in use (your own folder / built into this app /
  imported), its MANIFEST summary, any of the three payload files that are missing, and the buttons
  "Import Nicotine payload…", "Choose a folder…", "Use the built-in payload".
- **Boot** — runs the boot (below) on the one HomePod in DFU. If gaster or irecovery is not on this
  Mac the card says so *before* the boot and offers "Install tools…" (the Setup page's installer).
  The button stays blocked until the boot loaders exist.
- **Boot loaders** — "Build release boot loaders…" (or "Rebuild…"), the folder they are in, and
  "Show in Finder".
- **Running HomePod** — once the pod answers at `172.16.42.1`: its version line (`PRETTY_NAME` and
  `VERSION` from `/etc/os-release`, read over SSH), **Open web UI** (`http://172.16.42.1/`),
  **Restore saved settings** and **Save settings**, and the switch **Restore saved settings
  automatically after boot** (on by default). "Check again" finds a pod booted earlier.
  With Nicotine build 117 on the pod there are two more buttons: **Wait in DFU at every power-up**
  (and its opposite, **Let it start by itself again**) and **Restart into DFU**. They talk to the
  pod's `startup.cgi` (`NicotineStartup` in the core, with curl); what they do on the pod is in
  [nicotine/README.md](../nicotine/README.md). Before switching "wait in DFU" on, the app saves a
  copy of the pod's first boot loader to `~/Library/Application Support/HomePod Hospital/Boot Loader
  Copies/`.

The device card also offers it: "Boot Nicotine (Linux)" in the *Check health* menu (advanced options
on), and the "Boot Nicotine (Linux)" row among the options for a board with a hardware diagnosis.
Both start the boot and switch to the Nicotine page.

## The boot loaders

Nicotine needs a patched iBSS and iBEC. The app makes them from Apple's **release** boot loaders in
the audioOS 16.4 update (build 20L497), which anyone can download from Apple. It never sends Apple's
development iBoot. `ReleaseIBootBuilder` (`Sources/HomePodRestoreCore/ReleaseIBoot.swift`) does:

    find the 16.4 OTA on ipsw.me, read iBSS/iBEC out of it with HTTP range requests (about 1 MB)
    → gaster pwn; gaster decrypt          (decrypted on the pod itself, in pwned DFU)
    → hBootPatcher -airs                  (signature check, IORVBAR, AES)
    → IBootFlipCheck, iBEC only           (Apple's upside-down check: one call becomes a no-op)
    → IMG4Wrap                            (the app's own code, with the generic A8 ticket)

The ticket is `nicotine/prebuilt/0x7000.im4m`, copied into the app as
`Contents/Resources/nicotine-0x7000.im4m`. `hBootPatcher` is compiled from HoolockLinux's
`remote_boot` by `scripts/bundle-tools.sh`. No `img4`, `img4tool`, `ipsw`, Homebrew `make` or
`libirecovery` is needed for this step, and nothing is fetched from GitHub on the user's Mac. The
whole build runs under the app-wide unlock lock (`UnlockCoordinator`).

The result is `iBSS.img4` and `iBEC.img4`:

- with the built-in or an imported payload: `~/Library/Application Support/HomePod Hospital/Nicotine
  Release iBoot/` (the app bundle must not be written into)
- with your own folder: `<folder>/release-iboot/`

They are kept per Mac, not per pod: the app does not rebuild them for another HomePod. So far they
have been built and used on one pod only.

**Manual alternative.** `scripts/prep-release-iboot.sh` is the older terminal route to the same two
files. It runs HoolockLinux's `remote_boot prep` unchanged (pinned) and needs the pod in DFU, the
Xcode command line tools, and `brew install blacktop/tap/ipsw libirecovery make` (ipsw 3.1.719 or
newer). To use its output in the app, point it at the app's folder:

```bash
RELEASE_IBOOT_OUT="$HOME/Library/Application Support/HomePod Hospital/Nicotine Release iBoot" bash scripts/prep-release-iboot.sh
```

It also leaves its `remote_boot` checkout and `prep.log` in that folder. Its closing message refers
to `boot-linux.sh`, which is not in this repository; ignore that and boot from the app.

## The boot sequence

`NicotineBooter` (`Sources/HomePodRestoreCore/NicotineBooter.swift`) runs these commands, the same
as the reference script `boot-linux.sh` with `IBOOT_DIR` set (that script lives with the Nicotine
developer's image folder, not in this repository):

| # | Command | If it fails | Pause after |
|---|---------|-------------|-------------|
| 1 | `gaster pwn` | stop | |
| 2 | `gaster reset` | stop | 1 s |
| 3 | `irecovery -f <boot loader folder>/iBSS.img4` | stop | 3 s |
| 4 | `irecovery -f <boot loader folder>/iBEC.img4` | stop | 4 s |
| 5 | `irecovery -f img4/RestoreDeviceTree_b238aap.img4` | stop | |
| 6 | `irecovery -c devicetree` | carry on | |
| 7 | `irecovery -f img4/RestoreTrustCache.img4` | carry on (older iBoots have no trust cache) | |
| 8 | `irecovery -c firmware` | carry on | |
| 9 | `irecovery -f img4/RestoreKernelCache_m1n1-linux.img4` | stop | |
| 10 | `irecovery -c bootx` | carry on | |

`RestoreKernelCache_m1n1-linux.img4` is not a kernelcache: it is m1n1 with the Linux kernel, device
tree and initramfs appended, wrapped with the `rkrn` tag so iBEC accepts it.

**Do not change this sequence in the app first.** Prove a change on a pod, then mirror it in
`NicotineBooter.steps(for:releaseIBoot:)`. `NicotineTests` and `ReleaseIBootTests` pin the list,
which failures stop the boot, and the pauses.

Around the sequence:

- Before the boot, `preflight` checks the three payload files, the two boot loaders, the MANIFEST
  checksums and the tools.
- The tools come from the app's tool locator (bundled → the app's own tools folder → Homebrew
  paths), not from the shell's `PATH`.
- The boot takes the app-wide unlock lock, like every other checkm8 boot.
- The app refuses to start unless exactly one HomePod is on USB and no restore or other boot is
  running, because the commands do not name a device.
- The UART console is not touched. If you log it (`screen` on the USB-serial adapter, 115200 8N1),
  keep doing that separately; it is the only place early-boot failures show.

## After the boot

- Reachability is `curl -s -o /dev/null -m 3 http://172.16.42.1/`, polled every 2 s for up to two
  minutes. curl, not URLSession, because App Transport Security refuses plain HTTP.
- The version is read with `/usr/bin/ssh … root@172.16.42.1 cat /etc/os-release`. Root needs no
  password; `BatchMode=yes` keeps ssh from ever prompting, and the host key is neither checked nor
  stored (it changes with every boot: the pod has no storage).
- **Settings.** A Nicotine build before 117 remembers nothing across a power cut; from 117 the pod
  keeps its settings on its own flash. Either way `homepod-config.sh` in the payload keeps one backup
  per pod on the Mac (WiFi networks and key, AirPlay name, Bluetooth pairings, sound and light
  settings). The app runs that script (`/bin/bash homepod-config.sh restore --wait 30` and
  `… save`) and reads its outcome (`NicotineSettings.outcome`). The backups contain the WiFi key.
  The restore the app does by itself after a boot is `restore --auto --wait 30`: a pod that has
  already put its own settings back keeps them (the backup must not undo what was changed on the
  pod since), takes only a boot sound of the user's own from the backup, and the Mac's copy is then
  refreshed from the pod, the file it replaces staying as `.prev`. "Restore saved settings" in the
  app is the plain restore and replaces the pod's settings.
- **Where the backups are.** With your own folder: `<folder>/config/`, the script's default. With
  the built-in or an imported payload: `~/Library/Application Support/HomePod Hospital/Nicotine
  Settings/`, passed to the script as `HOMEPOD_CONFIG_DIR`.
- **Automatic restore.** When the pod answers after a boot and the option is on, the app runs the
  restore once, but only if at least one backup exists in that folder. The script picks the backup
  for this pod by its unit ID; "no backup for this pod" is shown as information, not as an error.

## Where the payload comes from

A *payload* is three IMG4 files, `homepod-config.sh` and a `MANIFEST`:

```
MANIFEST
homepod-config.sh
img4/RestoreKernelCache_m1n1-linux.img4   the Nicotine image (about 67 MB)
img4/RestoreDeviceTree_b238aap.img4       Apple's device tree
img4/RestoreTrustCache.img4               empty trust cache
```

```
nicotine-payload 1
variant=public
created=2026-11-22T03:51:12Z
<sha256>  img4/RestoreKernelCache_m1n1-linux.img4
…one line per file
```

Unknown `key=value` header lines are ignored. The app looks for a payload in this order
(`NicotinePayloadLocator.resolve`):

1. **Your own folder** (`nicotineFolder` in UserDefaults; it defaults to
   `~/Downloads/diagsstuffnic/linux-homepod` when that exists). It may have no MANIFEST; then nothing
   is verified. A picked folder is used even if it is incomplete (the page says what is missing)
   until "Use the built-in payload" clears it.
2. **Built into the app**: `HomePod Hospital.app/Contents/Resources/Nicotine/`, put there by
   `./scripts/build-app.sh` unless `BUNDLE_NICOTINE=0`.
3. **Imported**: `~/Library/Application Support/HomePod Hospital/Nicotine/`, put there by
   "Import Nicotine payload…" (a payload folder or a `.zip` of one; the zip may have the files at
   its top or inside one folder).

When the payload has a MANIFEST, every listed file is hashed and compared before each boot, and an
import verifies before and after copying. A mismatch stops with "… is damaged or incomplete".
Imports copy exactly the files the MANIFEST lists, nothing else. There is no download-by-URL:
`NicotinePayloadImporter.payloadDownloadURL` is empty.

**Building one.** The build runs `nicotine/payload-from-ipsw.sh` on an audioOS 18.3 IPSW
(`NICOTINE_SRC_IPSW`, else a local copy, else downloaded once from nicsfix.com). The kernel, m1n1
and root filesystem come from the `nicotine/` kit; the device tree, the Bluetooth patch and the WiFi
firmware are Apple's and are fetched or extracted at build time. How, and what to look for in the build log:
[nicotine/README.md](../nicotine/README.md).

```bash
./scripts/build-app.sh                                        # build and bundle a payload
NICOTINE_PAYLOAD_DIR=~/nicotine-payload ./scripts/build-app.sh   # bundle one you already have
NICOTINE_PAYLOAD_DIR=~/nicotine-payload swift test --filter RealPayload   # check it with the app's code
```

The build fails if the payload has no MANIFEST, a listed file is missing or damaged, or one of the
three IMG4 files is not listed; and, with tools bundled, if gaster or irecovery did not make it into
the app. The payload is never committed (`.gitignore` covers `Nicotine-*/`, `Nicotine-*.zip`,
`*.img4`).

## Fresh Mac checklist

What a Mac that has never seen this project needs, and where it comes from with a default build:

| Needed for | What | In the app? |
|---|---|---|
| unlock (checkm8), decrypting the boot loaders | `gaster` (built from source with the ECID patch) | yes, `Resources/bin/gaster` |
| sending boot files | `irecovery` + libirecovery, libimobiledevice-glue, libplist | yes, `Resources/bin/`, libraries in `Contents/Frameworks/` |
| patching the boot loaders | `hBootPatcher` | yes, `Resources/bin/hBootPatcher` |
| wrapping the boot loaders | the generic A8 ticket | yes, `Resources/nicotine-0x7000.im4m` |
| boot files | three `.img4`, MANIFEST | yes, `Resources/Nicotine/` |
| settings save / restore | `homepod-config.sh` | yes, `Resources/Nicotine/`; needs only bash, curl, tar, gzip, sed |
| reaching the pod | `/usr/bin/curl`, `/usr/bin/ssh`, `/bin/bash`, `/usr/bin/unzip` (import) | part of macOS |
| the USB network | macOS's own USB-Ethernet driver | part of macOS |

Not covered:

- **CPU.** Bundled tools are for the build Mac's CPU only (`Resources/bin/ARCHS`). On another CPU
  the app ignores them and offers "Install tools…", which builds gaster and irecovery but not
  hBootPatcher. Such a Mac (and any app built with `BUNDLE_TOOLS=0`) cannot build the boot loaders,
  unless it uses `prep-release-iboot.sh`. A universal tool bundle is not built.
- **Gatekeeper.** The app is ad-hoc signed unless `SIGN_ID` is set: other Macs need right-click →
  Open the first time, and macOS may run it translocated. The payload is only read and everything
  written goes to Application Support, so this should not matter, but it has not been tried.
- **The hardware side**: the USB adapter for the debug port, and DFU.

## Security

As shipped today, a running Nicotine pod has no access control:

- SSH (dropbear, port 22) lets in `root` with no password, and it listens on WiFi as well as on
  the USB network.
- The web UI (port 80, also on WiFi) has no login, and its Terminal tab runs commands as root.
- Telnet on `172.16.42.1:23` (USB only) gives a shell without a login.

Only use a Nicotine pod on a network you trust. Restricting shell access to USB and adding a web UI
password is planned.

## Code map

| Where | What |
|-------|------|
| `Sources/HomePodRestoreCore/NicotineBooter.swift` | `NicotineLayout` (folder, payload files, `release-iboot/`), `NicotineBooter` (the sequence; `preflight`), `NicotinePod` (reachability, version), `NicotineSettings` (runs homepod-config.sh), `NicotineError`, `ErrorCatalog.nicotine` |
| `Sources/HomePodRestoreCore/NicotinePayload.swift` | `NicotineManifest`, `NicotinePayload`, `NicotinePayloadLocator` (lookup order), `NicotinePayloadVerifier`, `NicotinePayloadImporter`, `NicotineHash` |
| `Sources/HomePodRestoreCore/ReleaseIBoot.swift` | `ReleaseIBootBuilder` (download, decrypt, patch, wrap), `IMG4Wrap` |
| `Sources/HomePodRestoreCore/IBootFlipCheck.swift` | finds Apple's upside-down check in the second stage by its shape and takes it out; `isPresent` for boot loaders that are already built. Tests: `IBootFlipCheckTests.swift` (made-up code; a real second stage with `HOMEPOD_IBEC_DEC=…`) |
| `Sources/HomePodRestoreCore/NicotineStartup.swift` | the pod's `startup.cgi`: "DFU at every power-up" on / off, restart into DFU, a copy of the first boot loader |
| `Sources/HomePodRestoreCore/TicketVault.swift` | `TicketVault` (which versions, where the tickets are kept, the tsschecker call), `TicketKeeper` (once per pod and run, from the USB device list) |
| `Sources/HomePodRestore/AppModelNicotine.swift` | page state, `bootNicotine(reveal:)`, `nicotineBlocker()`, `prepareNicotineReleaseIBoot()`, `nicotineReleaseIBootDir`, import, pod check, save / restore settings, automatic restore, `setNicotineDFUAtPowerUp`, `restartNicotineIntoDFU` |
| `Sources/HomePodRestore/Views/NicotineView.swift` | the page |
| `Sources/HomePodRestore/Views/RootView.swift`, `DeviceCard.swift` | sidebar section; the two "Boot Nicotine (Linux)" entry points |
| `Tests/HomePodRestoreCoreTests/NicotineTests.swift`, `ReleaseIBootTests.swift`, `NicotinePayloadTests.swift` | sequence and boot-loader swap pinned; fake-tool runs; MANIFEST parsing and verification; import; optional real-payload check |
| `Tests/HomePodRestoreCoreTests/NicotineBuild117Tests.swift`, `NicotineStartupTests.swift`, `TicketVaultTests.swift` | the automatic restore's arguments and outcomes; telling the boot loader's DFU from the chip's; `startup.cgi` answers; ticket names, candidates and outcomes |
| `scripts/build-app.sh`, `scripts/bundle-tools.sh` | payload build and bundling; tool bundling, hBootPatcher |
| `nicotine/` | the payload build kit (see its README) |

## Status

- **Tried on hardware, one pod**: the app built with the payload inside, the boot loaders built in
  the app, and Nicotine booted from the Nicotine page with WiFi and Bluetooth working.
- **Not yet run**: the build with tools and payload on by default (the flags changed after that
  test), `nicotine/kernel/build.sh`, the boot-loader build or a boot on a second pod or a second
  Mac, import of a zip in the real app, the tool-install prompt on a Mac without tools, and
  `prep-release-iboot.sh` writing into the app's folder.
- `IMG4Wrap` has no unit test of its own; it is meant to write the same bytes as `nicotine/tools/pack.py`.

## Ideas not done

- Passing the pod's ECID to gaster (`GASTER_ECID`, patched build) and `irecovery -i`, so that several
  pods could be connected.
- Download of a payload by URL (deliberately absent; see `payloadDownloadURL`).
- A universal (arm64 + x86_64) tool bundle, so other Macs need no installer either.
- Picking the WiFi calibration file and Bluetooth patch by radio module vendor (only the USI
  variants are built today).
