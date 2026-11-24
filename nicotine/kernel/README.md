# Nicotine kernel and boot loader sources

`../prebuilt/` holds four files that are built from source on a Linux machine
and committed, because the app is built on macOS and cannot cross-compile a
kernel:

| Prebuilt file | Built from | License |
|---|---|---|
| `Image.gz` | Linux, HoolockLinux tree at `ed8528f48` + `linux-homepod.patch`, with `config` | GPL-2.0 |
| `t7000-b238a.dtb` | `arch/arm64/boot/dts/apple/t7000-b238a.dts`, added by the same patch | GPL-2.0+ OR MIT |
| `m1n1-idevice.macho`, `monitor-stub.macho` | m1n1, HoolockLinux tree at `d5a10ac5` + `m1n1-homepod.patch` | MIT |

This folder is the corresponding source for those binaries:

- **`linux-homepod.patch`** — everything Nicotine changes in the kernel (14 files,
  about 2,000 added lines), as one patch against
  <https://github.com/HoolockLinux/linux> commit
  `ed8528f482a526371e59711645794c91fafb2b42`:
  - `drivers/pci/controller/pcie-apple.c`: the Apple A8 (T7000) PCIe root
    complex, including powering the WiFi chip through the PMIC.
  - `drivers/iommu/apple-dart.c`, `io-pgtable-dart.c`: fixes for the A8's DART
    (page-table entry format, cache coherency, translation control).
  - `drivers/net/wireless/broadcom/brcm80211/brcmfmac/`: BCM4357 support and
    the fixes that make it work behind the A8's PCIe port (bus-address offset
    for DMA, ring index padding, and bring-up diagnostics that are still in).
  - `arch/arm64/boot/dts/apple/t7000-b238a.dts`: the HomePod device tree.
  - `drivers/video/backlight/apple_pmic_bl.c`: a two-line build fix.
  - `drivers/block/asp.c` (the NAND driver): four of the small NAND areas can be
    written, each behind its own switch in `/sys/module/asp/parameters/` that is
    off after boot. A write must also start at the area's first sector (the
    controller takes nothing else).
    - `paniclog_rw`: the panic log area (`asp0n10`), where Nicotine keeps its
      settings (`homepod-nvstore`).
    - `llb_rw`: the LLB area (`asp0n2`), written by `homepod-dfu-mode` to make a
      pod start in DFU at every power-up, and to undo that.
    - `fw_rw`, `nvram_rw`: the second boot loader (`asp0n3`) and iBoot's NVRAM
      (`asp0n8`). Nothing in normal use writes them; they exist for installing
      another Apple-signed boot chain and for boot loader research.
    SysCfg, the effaceable area and the controller's own areas stay read-only.
    At reboot the driver now only flushes the write cache; it used to run its
    whole remove path, which is the suspected reason `reboot` never reached the
    reset on a HomePod.
- **`config`** — the exact kernel configuration of the shipped `Image.gz`
  (4K pages, everything built in, no modules).
- **`m1n1-homepod.patch`** — one change to m1n1 (`src/fb.c`: skip framebuffer
  setup when iBoot passes none), against
  <https://github.com/HoolockLinux/m1n1> commit
  `d5a10ac52a6468484854419a6c5130f1d62073eb`.
- **`build.sh`** — clones both trees at those commits, applies the patches,
  builds, and copies the four files into `../prebuilt/`.

## Rebuilding

On a Linux machine (Debian/Ubuntu package names):

```
sudo apt install git make bc bison flex libssl-dev libelf-dev gcc-aarch64-linux-gnu clang lld
./build.sh
```

The shipped kernel is build #102, compiled with `aarch64-linux-gnu-gcc` 13.3.
A rebuild will not be byte-identical (the kernel embeds a build number and
time), but it is the same source and configuration.

`linux-homepod.patch` was checked to apply cleanly to the base commit, and the
device tree it adds compiles to exactly the `t7000-b238a.dtb` in `../prebuilt/`.
`build.sh` itself has not been run end to end; treat it as the recipe written
down, and fix it here if a step is off.

## What is not here yet

The root filesystem (`../rootfs-skeleton.tar.gz`) contains prebuilt user-space
programs: BusyBox, dropbear, BlueZ and bluez-alsa, wpa_supplicant, iw,
shairport-sync (patched), Python, and Nicotine's own programs (the audio
feeder `hpfeed`, the service scripts, the web UI). The scripts and the web UI
are readable as they are inside the tarball. The sources and patches for the
compiled programs are not in this repository yet.
