# HomePod Hospital

**Restore, diagnose and revive the original HomePod from a Mac, over USB.**

HomePod Hospital is a Mac app for the 1st-generation HomePod (A1639, `AudioAccessory1,1`). It
reinstalls Apple's software in one click, tells you in plain English whether a fault is software
or hardware, and can boot **Nicotine**: a small Linux system that turns a HomePod into a
standalone AirPlay and Bluetooth speaker, including boards that can no longer run Apple's software.

![The Restore tab, waiting for a HomePod, with the five connection steps](docs/images/app-restore.png)

## What you can do with it

| Feature | What it does |
|---|---|
| **Restore** | Reinstall audioOS on one HomePod or several at once. Fixes boot loops, blinking volume buttons and failed setups or updates. |
| **Health check** | Find out whether a problem is software or hardware before you erase anything. |
| **Firmware** | Download the ready-made 18.3 firmware, add your own `.ipsw`, or build one from Apple's files. |
| **Change color** | Switch the color a HomePod reports between Space Gray and White. |
| **Factory diagnostics** | Run Apple's DIAGS commands with buttons instead of typing them into a serial console. |
| **Nicotine (Linux)** | Boot a HomePod as an AirPlay 2 and Bluetooth speaker with its own web page for sound, WiFi and lights. |

Only the 1st-generation HomePod is supported. HomePod mini and HomePod (2nd generation) are not.

## What you need

- A Mac running macOS 13 or later.
- A 1st-generation HomePod and a USB adapter for the debug port under its rubber base
  ([Nic's Fix shop](https://nicsfix.com/shop)).
- For the factory diagnostics only: a USB-to-serial (UART) adapter.

## Get started

```bash
git clone https://github.com/UnbendableStraw/HomePod-Hospital.git
cd HomePod-Hospital
./scripts/setup-tools.sh        # once per Mac: installs the restore tools (asks for your password)
brew install dylibbundler       # once per Mac
./scripts/build-app.sh          # → dist/HomePod Hospital.app
open "dist/HomePod Hospital.app"
```

The build needs Xcode or the Command Line Tools and `python3`. The first build downloads the
audioOS 18.3 firmware (about 3.4 GB) unless it finds a copy, for example `~/Downloads/18.3.ipsw`. The
finished app has the restore tools and Nicotine inside, so there is nothing else to install.

The app is not signed with a Developer ID. On another Mac, right-click it and choose **Open** the
first time.

Then connect a HomePod. The Restore tab shows the same steps:

1. Pry off the rubber base to reach the debug port (first time only).
2. Press the USB adapter onto the port.
3. Plug the USB cable into your Mac. Leave the HomePod's power unplugged.
4. Turn the HomePod upside down.
5. Plug in HomePod power **last**. USB first, then power.
6. When the HomePod appears in the app in DFU mode, turn it right-side up — **then** click Restore.
   It stays in DFU when you turn it over. **Show me how** next to the Restore and Boot buttons
   walks through it in three steps — connect (upside down), power (it waits until the Mac sees
   DFU mode, with tips if it doesn't), right-side up — and clicking **Done** starts that restore or boot.

## A tour of the app

### Restore

Each connected HomePod gets its own card with one button. Progress is shown as plain steps
instead of a wall of log lines, and failures come with an explanation and what to try next.
Turn on **Restore automatically when plugged in** to work through a stack of HomePods.

### Health check

![The Health Check tab with the quick check, the boot test and the diagnostics buttons](docs/images/app-health-check.png)

- **Quick check** (about 30 seconds) confirms the USB link, the chip and that the HomePod can be
  unlocked.
- **Boot test** (2 to 3 minutes) starts Apple's restore software and stops. Nothing is erased.
- Storage (NAND) is judged during a real restore, and the Restore tab says so in plain words when
  it fails.

### Factory diagnostics and color change

![The DIAGS Shell tab with quick-action buttons for device info, SysCfg, NAND, audio, sensors and LEDs](docs/images/app-diags-shell.png)

The DIAGS Shell tab talks to Apple's factory diagnostics over a serial adapter. **Reconfigure
Model…** rewrites the three settings that carry a HomePod's color (Space Gray or White). After a
restore, the setup prompt on your iPhone shows the new color. Details are in
[docs/diags-boot.md](docs/diags-boot.md).

### Firmware and Setup

<table>
<tr>
<td width="50%" valign="top">
<b>Firmware.</b> Most people only need the recommended download. The app also shows which versions Apple still signs, because only those can be installed. <b>Build your own</b> makes an <code>.ipsw</code> from Apple's own HomePod update with <a href="https://github.com/tihmstar">tihmstar's</a> <code>makeipsw.sh</code>.
<br><br>
<img src="docs/images/app-firmware.png" alt="The Firmware tab with the recommended 18.3 download and the build-your-own option">
</td>
<td width="50%" valign="top">
<b>Setup.</b> Shows which tools the app is using and where its logs, firmware and caches are kept. An app built the default way has the tools inside, so there is nothing to do here.
<br><br>
<img src="docs/images/app-setup.png" alt="The Setup tab showing that the tools are built into the app">
</td>
</tr>
</table>

## Nicotine: Linux on a HomePod

Nicotine makes a HomePod a standalone AirPlay and Bluetooth speaker. It runs entirely from memory, so unplugging power brings back
whatever was on the HomePod before, and the Mac has to start it again after every power cut. From build 117 it keeps its own
settings in a small spare area of the HomePod's flash (the WiFi key included; the web UI can switch that off, which deletes
them), so a freshly booted HomePod is back on your WiFi by itself. Nothing else on the HomePod is written unless you ask for
it: see "Booting without turning it over" below.

![The Nicotine tab with the payload, boot, boot loaders and running HomePod cards](docs/images/app-nicotine.png)

### Booting it

1. **Once per Mac:** with a HomePod in DFU mode, open the **Boot loaders** card and click
   **Build release boot loaders**. The app builds them from Apple's audioOS 16.4 update.
2. Put the HomePod in DFU mode: adapter on and USB in the Mac, upside down, then power.
3. Once it shows up in DFU mode, turn the HomePod right-side up, then click **Boot Nicotine**.
4. After 30 to 40 seconds **Open web UI** appears. The HomePod answers at `http://172.16.42.1/`
   over the USB cable.
5. Join your WiFi in the web UI's WiFi tab. The HomePod then shows up as an AirPlay speaker.
6. Settings you change are kept on the HomePod itself (build 117). The Mac keeps a second copy: it brings it up to
   date after every boot, and **Save settings** does that on demand.

More detail, and what to do when a step fails, is in [docs/nicotine-boot.md](docs/nicotine-boot.md).

### Booting without turning it over

Once Nicotine is running, the **Running HomePod** card has two more buttons (the web UI has them too, on the Overview
tab under "Starting and restarting"):

- **Wait in DFU at every power-up.** From then on the HomePod is in DFU a few seconds after it gets power, whichever way
  up it is: plug it in and click **Boot Nicotine**. While this is on, the HomePod cannot start audioOS by itself;
  **Let it start by itself again** undoes it, and so does a restore. It works by changing one byte of the first boot
  loader on the HomePod's flash. The app saves a copy of that boot loader on the Mac first.
- **Restart into DFU.** Puts the running HomePod into DFU once, without unplugging it or turning it over.

Turning the HomePod right-side up before **Boot Nicotine** (step 3) matters with boot loaders built by an earlier
version of the app: Apple's boot loader sends an upside-down HomePod straight back to DFU. The builder now takes that
check out, so with boot loaders built from this version on the HomePod boots in any position. The **Boot loaders** card
tells you when yours still have the check; **Rebuild release boot loaders** replaces them.

### Signing tickets

The app saves Apple's signing tickets for every HomePod it sees in DFU or recovery mode, for the software versions
Apple still signs (in November 2026 that included 13.4.8 and 18.3). They are in `Tickets/` in the app's Application Support
folder, one folder per HomePod. A ticket makes a version valid for one HomePod and can only be fetched while Apple
still gives it out; a saved one keeps working for boot loaders that start from the HomePod's own flash. The HomePod's
ID is sent to Apple's signing server and nowhere else. To switch this off:
`defaults write com.nicsfix.homepodrestore saveSigningTickets -bool NO`.

### The web UI

Every Nicotine HomePod serves its own control page, over USB and over WiFi.

![Now Playing: track, artist, transport buttons and volume](docs/images/webui-now-playing.png)

<table>
<tr>
<td width="50%" valign="top">
<b>Live meters.</b> Woofer movement, power draw, limiter activity and temperatures while music plays.
<br><br>
<img src="docs/images/webui-live.png" alt="Live tab with the speaker diagram, power bar, protection and temperatures">
</td>
<td width="50%" valign="top">
<b>Speaker.</b> Volume, sound profile, loudness, placement, left or right for a pair, and which way the speaker faces.
<br><br>
<img src="docs/images/webui-speaker.png" alt="Speaker tab with volume, sound settings and the soundstage direction picker">
</td>
</tr>
<tr>
<td width="50%" valign="top">
<b>Equalizer and Sound Glow.</b> A 10-band equalizer with presets, and the top light pulsing with the music in colors taken from the album art, your own colors, other animations or an always-on effect.
<br><br>
<img src="docs/images/webui-equaliser-glow.png" alt="Equaliser sliders and the Sound Glow settings">
</td>
<td width="50%" valign="top">
<b>WiFi.</b> Signal, link rate, saved networks, scan and join.
<br><br>
<img src="docs/images/webui-wifi.png" alt="WiFi tab with connection details and saved networks">
</td>
</tr>
<tr>
<td width="50%" valign="top">
<b>Bluetooth.</b> Pair a phone from the page or by holding the top of the speaker.
<br><br>
<img src="docs/images/webui-bluetooth.png" alt="Bluetooth tab with the pairing button">
</td>
<td width="50%" valign="top">
<b>Overview.</b> System status and the settings backup.
<br><br>
<img src="docs/images/webui-overview.png" alt="Overview tab with system status and backup and restore">
</td>
</tr>
</table>

**Surround, Dolby Atmos and rooms.** Apple Music's Atmos plays as Atmos (the build takes Apple's
decoder from the audioOS IPSW you download; it is not in this repository). Several Nicotine
HomePods can form a room that shows up as one AirPlay speaker: a stereo pair, or a surround layout
where each speaker gets its own channels, with other AirPlay speakers on the network joining in if
you switch that on. It is set up on the Speaker tab; see [nicotine/README.md](nicotine/README.md).

There are also AirPlay, Devices, Network, Terminal and Logs tabs, and an optional boot sound
(off by default) that you can replace with your own. The touch surface on top works
too: **+** and **−** for volume, tap for play/pause, two taps for next track.

The screenshots show the real pages with the network name and addresses replaced, and a
generated picture in place of the album cover.

### Security

As shipped today, a running Nicotine pod is open to anyone who can reach it: SSH lets in `root`
with no password and listens on WiFi as well as on the USB cable, and the web UI has no login (its
Terminal tab runs commands as root). Only use it on a network you trust. Limiting shell access to
USB and adding a web UI password is planned.

## Build options

```bash
./scripts/build-app.sh                                   # tools and Nicotine inside (the default)
BUNDLE_NICOTINE=0 ./scripts/build-app.sh                 # no Nicotine; import a payload in the app later
BUNDLE_TOOLS=0 BUNDLE_NICOTINE=0 ./scripts/build-app.sh  # app only; users install tools via Setup
NICOTINE_SRC_IPSW=~/Downloads/18.3.ipsw ./scripts/build-app.sh   # build Nicotine from this IPSW
```

Nothing proprietary is stored in this repository. The Nicotine image is put together at build
time from the `nicotine/` kit here plus files fetched from Apple's own public downloads. See
[nicotine/README.md](nicotine/README.md).

## Getting help

- Ask in the [Nic's Fix Discord](https://discord.gg/nicsfix). Click **Copy support info** on the
  HomePod's card first and paste it into your message.
- The app's **Help & Credits** tab explains the common error messages.
- The step-by-step [homepod-restore guide](https://github.com/UnbendableStraw/homepod-restore)
  covers the hardware side.
- A restore cannot fix a HomePod with no power, failed storage (NAND), a failed processor or
  other hardware damage. [Nic's Fix](https://nicsfix.com) repairs those.

The app and the ready-made firmware are free. If it saved your HomePod, a
[donation](https://www.paypal.com/donate/?business=nicsfix) helps keep the downloads online.

## Status and limits

- **Tried on hardware, one pod**: the app built, the boot loaders built in the app, and Nicotine
  booted from the Nicotine page with WiFi and Bluetooth working. The color change is confirmed too.
- **Not yet run**: the newest build defaults (tools and payload on by default), the rewritten
  `hpdiag-*` diagnostic scripts, `nicotine/kernel/build.sh`, two pods at once with the patched
  gaster, two simultaneous idevicerestore runs, the admin-password build flow, any second Mac.
- The ready-made restore firmware is audioOS 18.3, and Nicotine is built from 18.3.
- Nicotine's WiFi calibration file and Bluetooth patch are the variants for the USI radio module.
  A pod whose module reports Murata worked with them in the one case tested, but nothing picks
  files by module vendor yet.
- Bundled tools are built for the build Mac's CPU only.

## More documentation

- [docs/development.md](docs/development.md): build details, tests, source layout, the gaster
  patch, the remote manifest and where the app keeps its files.
- [docs/nicotine-boot.md](docs/nicotine-boot.md): how the Nicotine boot works.
- [nicotine/README.md](nicotine/README.md): the Nicotine build kit, kernel and firmware sources.
- [docs/diags-boot.md](docs/diags-boot.md): factory DIAGS and the color change.
- [docs/ssh-ramdisk-runbook.md](docs/ssh-ramdisk-runbook.md): the SSH ramdisk diagnostics.

## Credits

HomePod USB restores exist thanks to years of work by
[tihmstar](https://github.com/tihmstar), [David Ryskalczyk (d235j)](https://github.com/d235j),
[0x7ff](https://github.com/0x7ff/gaster), [HoolockLinux](https://github.com/HoolockLinux) and
[libimobiledevice](https://github.com/libimobiledevice). Please support them.

Made by [Nic's Fix](https://nicsfix.com).
