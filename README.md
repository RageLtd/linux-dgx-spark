# linux-dgx-spark

Arch Linux kernel package for the NVIDIA DGX Spark (GB10 Grace-Blackwell).

## Acknowledgements

This project builds on the work of others:

- **[graham33/nixos-dgx-spark](https://github.com/graham33/nixos-dgx-spark)** — did the hard work of reverse-engineering NVIDIA's kernel config requirements from their Debian package annotations and validating them on real hardware. Our config generation pipeline directly consumes their NixOS kernel config delta.
- **[NVIDIA / Canonical](https://launchpad.net/ubuntu/+source/linux-nvidia-6.17)** — the kernel source itself comes from NVIDIA's Ubuntu kernel fork published on Launchpad, which includes patches for ConnectX-7 networking and Grace-Blackwell SoC support not yet in mainline Linux.
- **[linux-cachyos](https://github.com/CachyOS/linux-cachyos)** — PKGBUILD structure and packaging patterns used as a reference for the Arch kernel package layout.

---

Builds NVIDIA's custom kernel with the DGX Spark config. The kernel version
is auto-detected from nixos-dgx-spark and fetched from Launchpad.

## Why this exists

The DGX Spark ships with NVIDIA's Ubuntu fork (DGX OS). The stock Ubuntu kernel
is required for working Ethernet (ConnectX-7) and full GPU support — a standard
kernel lacks the necessary patches. This package brings that kernel to Arch Linux.

## Status

> **Early / experimental.** Boot testing welcome.

## Building

### Prerequisites

- Docker with `linux/arm64` support (Apple Silicon runs this natively)
- Or a native aarch64 Linux machine

### Quick build (recommended)

```bash
./build.sh
```

This handles everything: downloads sources to `cache/`, builds the Docker
container, generates the kernel config, and runs `makepkg`. Subsequent runs
are incremental — only changed files recompile.

Individual steps can be run separately:

```bash
./build.sh download   # only download sources to cache/
./build.sh config     # download + generate configs/config.aarch64
./build.sh pkg        # only run makepkg (config must already exist)
```

### 64K page-size variant

```bash
./build.sh -p 64k
```

Builds `linux-dgx-spark-64k` — the same kernel with 64K pages, mirroring the
`kernel-64k` variant Red Hat ships for the GB10. NVIDIA recommends 64K pages
for Grace-class unified memory throughput, at the cost of higher memory
overhead and possible breakage in userspace that assumes 4K pages (some
Electron builds, `box64`, older jemalloc). Both variants install side by side
(separate pkgbase, modules, and initramfs) so you can A/B them from the
bootloader menu. The 4K and 64K builds keep separate incremental build trees
in the Docker volume.

To force a clean build, delete the Docker volume:

```bash
docker volume rm dgx-spark-builddir
```

### Native aarch64 build (no Docker)

If you're on an aarch64 Arch machine, you can build directly:

```bash
./scripts/gen-config.sh          # generate configs/config.aarch64
makepkg -s --noconfirm           # build the packages
```

### Output

- `linux-dgx-spark-<ver>-aarch64.pkg.tar.xz` — kernel + modules
- `linux-dgx-spark-headers-<ver>-aarch64.pkg.tar.xz` — headers for DKMS/module builds

### Install on the Spark

```bash
sudo pacman -U linux-dgx-spark-*.pkg.tar.xz
sudo grub-mkconfig -o /boot/grub/grub.cfg
reboot
```

pacman's `initramfs` hook runs `mkinitcpio` automatically.

## How it works

```
nixos-dgx-spark/kernel-configs/  →  scripts/apply-nix-config.ts
      (NixOS config delta)                    ↓
                                    ARM64 defconfig + delta
                                              ↓
                                    make olddefconfig
                                              ↓
                                    configs/config.aarch64
                                              ↓
                                         PKGBUILD
```

The NixOS repo generates a terse config containing only options that differ from
upstream defaults, reducing noise by ~82%. We parse that delta and apply it on
top of the ARM64 defconfig using the kernel's own `scripts/config` tool.

## Contributing

PRs welcome, especially:
- Keeping up with new kernel versions from NVIDIA
- Testing on the Asus Ascent GX10 (same GB10 silicon)

## GPU driver

No companion driver package is needed: Arch Linux ARM ships `nvidia-open-dkms`
and `nvidia-utils` for aarch64 (610.57.04+, which supports the GB10). Install
them alongside `linux-dgx-spark-headers` and DKMS builds the open kernel
modules (nvidia, nvidia-uvm, nvidia-drm, nvidia-modeset, nvidia-peermem) for
every installed kernel variant automatically.

## License

PKGBUILD and scripts: MIT
Linux kernel: GPL-2.0
