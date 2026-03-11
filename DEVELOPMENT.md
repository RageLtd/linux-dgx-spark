# Development Log

History of what was built, bugs hit, and what still needs verification.

---

## What was built

### Goal

A PKGBUILD to produce an Arch Linux kernel package for the NVIDIA DGX Spark
(GB10 Grace-Blackwell, aarch64). The DGX Spark requires NVIDIA's custom kernel
for working ConnectX-7 Ethernet and GPU support — neither is functional with a
stock upstream kernel.

No Arch playbook existed for this hardware. The approach was to adapt the work
from [graham33/nixos-dgx-spark](https://github.com/graham33/nixos-dgx-spark),
which had already done the hard work of extracting NVIDIA's kernel config
annotations from their Debian package.

### Files

| File | Purpose |
|------|---------|
| `build.sh` | End-to-end build script (container + config + packages) |
| `PKGBUILD` | Arch kernel package definition |
| `Dockerfile` | Native aarch64 Arch build environment (for Apple Silicon) |
| `scripts/gen-config.sh` | Generates `configs/config.aarch64` and `configs/version.env` from upstream sources |
| `scripts/apply-nix-config.ts` | Bun/TypeScript — parses NixOS config delta, applies it via `scripts/config` |
| `configs/` | Output directory for the generated kernel config and version metadata |
| `patches/` | Optional local patches applied in `prepare()` |

### How `gen-config.sh` works

1. Clones `nixos-dgx-spark` (depth=1) to read NVIDIA's validated config delta
2. Extracts the kernel series from the config filename (e.g. `nvidia-dgx-spark-6.17.1.nix` → series `6.17`)
3. Queries the Launchpad API (`getPublishedSources`) to find the latest published version of `linux-nvidia-6.17`
4. Downloads the orig tarball + Debian diff from Launchpad
5. Applies the Debian patch series with `patch -Np1`
6. Runs `make ARCH=arm64 defconfig` as the baseline
7. Calls `apply-nix-config.ts` to apply the NixOS config delta via the kernel's own `scripts/config`
8. Runs `make ARCH=arm64 olddefconfig` to resolve any remaining dependencies

### Why a native aarch64 container

`makepkg` produces packages for the host arch. Building on Apple Silicon in
a `--platform linux/arm64` Docker container gives native aarch64 without
cross-compilation, QEMU emulation, or a cross-toolchain. The Dockerfile sets
up an Arch `base-devel` environment with all kernel build deps.

---

## Bugs encountered and fixed

### 1. `bun` not in Arch official repos

**Symptom:** `pacman -S bun` fails — bun is AUR-only on Arch Linux.

**Fix:** Install via the official bun install script as the `builder` user in
the Dockerfile:
```dockerfile
USER builder
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/home/builder/.bun/bin:${PATH}"
```

---

### 2. Missing `--platform linux/arm64` flags in README

**Symptom:** On Apple Silicon, `docker build` and `docker run` without
`--platform` may default to `linux/amd64` via Rosetta emulation instead of
running natively as aarch64.

**Fix:** Added `--platform linux/arm64` to both `docker build` and `docker run`
commands throughout the README.

---

### 3. PKGBUILD source path for config wrong

**Symptom:** `makepkg` could not find the config file.

**Root cause:** PKGBUILD `source=()` referenced `config.aarch64` but the file
lives at `configs/config.aarch64`.

**Fix:**
```bash
# Before
"config.aarch64::${startdir}/configs/config.aarch64"

# After — use the path relative to the repo root
"${startdir}/configs/config.aarch64"
```

---

### 4. `configs/` and `patches/` directories not tracked by git

**Symptom:** Freshly cloned repo was missing `configs/` and `patches/`
directories, breaking `gen-config.sh` output and `makepkg`.

**Fix:** Added `.gitkeep` files to both directories and updated `.gitignore`
to un-ignore them:
```gitignore
!configs/.gitkeep
!patches/.gitkeep
```

---

### 5. Missing `LICENSE` file

**Fix:** Added `LICENSE` (MIT) covering the PKGBUILD and scripts.

---

### 6. Extracted kernel source directory name assumed, not detected

**Symptom:**
```
cd: /tmp/.../linux-nvidia-6.14-6.14.0: No such file or directory
```
The tar extracts to a directory named differently than assumed (e.g. `linux-6.14`
instead of `linux-nvidia-6.14-6.14.0`).

**Fix:** Detect the extracted directory dynamically:
```bash
KSRC=$(find "$WORK_DIR" -mindepth 1 -maxdepth 1 -type d | grep -v nixos-dgx-spark | head -1)
```

---

### 7. Hardcoded kernel version fetching wrong source

**Symptom:** Script hardcoded `_kernelver=6.14.0` but `nixos-dgx-spark` had
already moved to tracking `6.17.1`.

**Fix:** Derive the kernel series from the config filename at runtime:
```bash
_basename=$(basename "$NIX_CONFIG")         # nvidia-dgx-spark-6.17.1.nix
_stripped="${_basename#nvidia-dgx-spark-}"  # 6.17.1.nix
KVER_FULL="${_stripped%.*}"                 # 6.17.1
KVER_SERIES="${KVER_FULL%.*}"               # 6.17
LAUNCHPAD_PKG="linux-nvidia-${KVER_SERIES}"
```

---

### 8. `zcat` fails on macOS (BSD)

**Symptom:**
```
zcat: can't stat: /tmp/.../file.diff.gz (.diff.gz.Z): No such file or directory
```
macOS `zcat` expects `.Z` compressed files, not `.gz`.

**Fix:** Replace `zcat` with `gzip -dc` which works on both macOS and Linux:
```bash
gzip -dc "${WORK_DIR}/${DIFF_GZ}" | patch -Np1
```

---

### 9. BSD `sed` alternation syntax broken on macOS

**Symptom:** Version string came out as `6.17.1.nix` instead of `6.17.1`
because BSD `sed` doesn't support `\(...\|...\)` BRE alternation.

**Fix:** Replaced all version-parsing `sed` with bash parameter expansion,
which is portable and requires no external tools:
```bash
KVER_FULL="${_stripped%.*}"   # strips last extension
```

---

### 10. `grep` in version parse pipeline exits nonzero under `set -e`

**Symptom:** Script silently died after printing the Launchpad curl progress —
`grep` returned exit code 1 when no match was found, and `set -euo pipefail`
killed the process before the empty-check error message could print.

**Fix:** Append `|| true` to the grep pipeline so the empty-check runs and
produces a useful error message with the full API response:
```bash
PKG_VERSION=$(echo "$LP_JSON" \
  | grep -o '"source_package_version": "[^"]*"' \
  | head -1 \
  | sed 's/"source_package_version": "//; s/"//') || true
```

---

### 11. Wrong Launchpad API endpoint (no `version` field)

**Symptom:**
```
ERROR: Could not parse 'version' field from Launchpad API response
```
The response was a package overview object (`#distribution_source_package`)
which has no `version` field.

**Root cause:** Was querying:
```
https://api.launchpad.net/1.0/ubuntu/+source/linux-nvidia-6.17
```

**Fix:** Use the `getPublishedSources` operation on the primary archive, which
returns publishing records containing `source_package_version`:
```
https://api.launchpad.net/1.0/ubuntu/+archive/primary
  ?ws.op=getPublishedSources
  &source_name=linux-nvidia-6.17
  &exact_match=true
  &order_by_date=true
  &ws.size=1
```

---

### 12. `curl -s` silencing errors

**Symptom:** curl failures produced no output, making failures invisible.

**Fix:** Removed `-s` from all curl invocations. `-f` is retained (exits
nonzero on HTTP errors) but without `-s` the error message is printed to stderr.

---

### 13. No arm64 `archlinux:base-devel` image

**Symptom:** `docker build --platform linux/arm64` fails — the official
`archlinux:base-devel` image only publishes `linux/amd64`.

**Fix:** Switched to `menci/archlinuxarm:latest`, a community image that
publishes native `linux/arm64`. Installed `base-devel` as a package since the
base image is minimal.

---

### 14. Pacman Landlock sandbox fails in Docker

**Symptom:**
```
error: failed to init transaction (failed to initialize alpm library)
```
Pacman's Landlock filesystem sandboxing requires kernel capabilities not
available inside Docker containers.

**Fix:** Added `DisableSandbox` under `[options]` in pacman.conf:
```dockerfile
RUN sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf
```
**Note:** Must be under `[options]`, not appended to end of file.

---

### 15. Pacman `CheckSpace` fails on Docker read-only mount

**Symptom:** pacman fails checking available disk space because Docker mounts
`/etc/resolv.conf` read-only.

**Fix:** Disable CheckSpace in the Dockerfile:
```dockerfile
RUN sed -i 's/^CheckSpace/#CheckSpace/' /etc/pacman.conf
```

---

### 16. `gen-config.sh` permission denied in container

**Symptom:** `./scripts/gen-config.sh` inside Docker fails with permission
denied — the script doesn't have execute bits after bind-mounting from macOS.

**Fix:** Invoke with `bash ./scripts/gen-config.sh` instead of relying on
the shebang.

---

### 17. Launchpad downloads timing out inside Docker container

**Symptom:** `curl` to Launchpad URLs hangs/times out when run inside the
aarch64 Docker container on macOS, despite working on the host.

**Fix:** Restructured `build.sh` to download all sources on the host (where
networking is reliable) into a `cache/` directory, then bind-mount that into
the container. `gen-config.sh` accepts `--cache-dir` to use pre-downloaded
sources.

---

### 18. `scripts/config` rejects `CONFIG_` prefix

**Symptom:**
```
scripts/config: bad command: CONFIG_USB_SI4713
```
The kernel's `scripts/config` tool adds the `CONFIG_` prefix itself — passing
`CONFIG_FOO` results in it looking for `CONFIG_CONFIG_FOO`.

**Fix:** Strip the prefix before passing to `scripts/config`:
```typescript
const key = rawKey.replace(/^CONFIG_/, "");
```

---

### 19. `scripts/config` argument chunking splits flag+key pairs

**Symptom:** Random `scripts/config` errors when processing batched arguments.

**Root cause:** The flat array of arguments was sliced at a fixed index,
sometimes cutting between a flag (`--enable`) and its key argument.

**Fix:** Rewrote chunking to group by complete commands:
```typescript
const groups: string[][] = [];
for (const [rawKey, val] of configs) {
  const key = rawKey.replace(/^CONFIG_/, "");
  switch (val) {
    case "y": groups.push(["--enable", key]); break;
    case "m": groups.push(["--module", key]); break;
    // ...
  }
}
// Chunk by groups, not by flat array index
```

---

### 20. `makepkg` re-downloads sources despite cache

**Symptom:** `makepkg` downloads the orig tarball and diff from Launchpad even
though they already exist in `cache/`.

**Fix:** PKGBUILD `source=()` array now checks for cached files first and uses
local paths if available:
```bash
if [[ -f "${_cachedir}/${_orig}" ]]; then
  _orig_src="${_cachedir}/${_orig}"
else
  _orig_src="${_launchpad_base}/${_orig}"
fi
```
Also removed `config.aarch64` from `source()` — `prepare()` copies it directly.

---

### 21. Docker build context includes leftover build artifacts

**Symptom:** `docker build` fails with permission errors trying to copy
root-owned `pkg/` and `src/` directories from previous build attempts.

**Fix:** Created `.dockerignore` to exclude build artifacts:
```
src/
pkg/
cache/
*.pkg.tar.zst
.git/
log
```

---

### 22. DTB syntax errors from Qualcomm laptop device trees

**Symptom:** `make all` fails compiling device tree overlays for Qualcomm
laptop platforms (e.g. `sc8280xp`, `x1e80100`) that are present in the
Ubuntu diff but irrelevant to DGX Spark.

**Fix:** DGX Spark uses ACPI, not device trees. Changed build target:
```bash
# Before
make all
# After
make -j"$(nproc)" Image modules
```

---

### 23. Kernel build runs single-threaded

**Symptom:** Compilation was using only 1 core despite the container having
access to all host cores.

**Fix:** Added `-j"$(nproc)"` to the make command in `build()`.

---

### 24. Ubuntu diff creates files already merged upstream

**Symptom:** `patch -Np1` fails with redefinition errors for `pinctrl-mt8901.c`,
`kvm/rme.c`, and `fs/proc/version_signature.c` — the Ubuntu diff contains
new files that were already merged into mainline 6.17.

**Root cause:** The `dpkg-source` format diff uses `.orig/` paths (not
`--- /dev/null`) for new file hunks. Detecting these requires matching
`@@ -0,0 ` (file created from line 0) and grabbing the `+++ ` path above.
The first path component must be stripped (same as `patch -Np1`).

**Fix:** Before applying the diff, scan for new-file hunks and delete any
pre-existing files so the diff can recreate them cleanly:
```bash
grep -B2 '^@@ -0,0 ' "$_difffile" \
  | grep '^+++ ' \
  | sed 's|^+++ [^/]*/||; s/[[:space:]].*//' \
  | sort -u \
  | while read -r f; do
      if [[ -n "$f" && -f "$f" ]]; then
        rm -f "$f"
      fi
    done || true

patch -Np1 --forward < "$_difffile" || true
```
**Key details:**
- Must use `[^/]*/` not `[ab]/` — dpkg-source uses `linux-nvidia-6.17-6.17.0.orig/`
- Must strip trailing timestamps with `s/[[:space:]].*/`
- Must use `if/then` not `[[ ]] && cmd` — the latter returns 1 on false,
  which kills `prepare()` under `set -e`
- `|| true` after `done` is a safety net for the pipeline exit code

---

### 25. macOS case-insensitive filesystem causes file collision

**Symptom:** Extracting the kernel source on a macOS bind mount fails because
`xt_HL.c` and `xt_hl.c` collide — macOS HFS+/APFS is case-insensitive by
default.

**Fix:** Use a container-local ext4 filesystem (case-sensitive) for the build
directory via a Docker named volume:
```bash
docker run ... -v dgx-spark-builddir:/tmp/makepkg ...
# SRCDEST=/build (bind mount - for source caching)
# BUILDDIR=/tmp/makepkg (named volume - case-sensitive ext4)
```

---

### 26. Missing `version` file breaks package step

**Symptom:**
```
version: No such file or directory
```
The `_package()` function reads `$(<version)` but the kernel build doesn't
create this file automatically.

**Fix:** Added `make -s kernelrelease > version` at the end of `prepare()`.

---

### 27. UID remapping breaks sudo in container

**Symptom:**
```
sudo: you do not exist in the passwd database
```
Attempting `usermod -u $HOST_UID builder` while running as builder caused sudo
to fail because the UID change invalidated the current session.

**Fix:** Removed UID remapping entirely. Instead, `build.sh` passes
`HOST_UID`/`HOST_GID` as environment variables and runs `chown` on output
files after the build:
```bash
sudo chown ${HOST_UID}:${HOST_GID} /build/*.pkg.tar.*
```

---

### 28. `Image.gz` not found — wrong build target

**Symptom:**
```
install: cannot stat 'arch/arm64/boot/Image.gz': No such file or directory
```
`_package()` uses `$(make -s image_name)` which returns `Image.gz` (gzip
compressed), but `build()` was hardcoded to build `Image` (uncompressed).

**Fix:** Dynamically query the target in `build()` to match:
```bash
make -j"$(nproc)" "$(basename "$(make -s image_name)")" modules
```

---

### 29. `makepkg` produces `.pkg.tar.xz` not `.pkg.tar.zst`

**Symptom:** `build.sh` looked for `*.pkg.tar.zst` but the container's
makepkg defaulted to xz compression.

**Fix:** Changed all globs to `*.pkg.tar.*` to handle any compression format.

---

### 30. `makepkg` re-extracts sources on every run

**Symptom:** Every `./build.sh pkg` run re-extracted the tarball, re-applied
patches, and triggered a full recompile (~1-2 hours).

**Fix:** `build.sh` checks for the `version` file that `prepare()` writes.
If it exists in the BUILDDIR volume, the source tree is already prepared
and `makepkg -e` is used to skip extraction and go straight to build:
```bash
if [[ -f /tmp/makepkg/.../version ]]; then
  makepkg -e -s --noconfirm    # incremental
else
  makepkg -s --noconfirm       # fresh
fi
```
To force a clean build: `docker volume rm dgx-spark-builddir`

---

## Verified

### `getPublishedSources` version parse — CONFIRMED
Tested live against Launchpad. The API returns `source_package_version: "6.17.0-1012.12"`
and the parsing produces correct `KERNEL_VER=6.17.0`, `UBUNTU_PKG=1012.12`.

### Launchpad download URLs for `linux-nvidia-6.17` — CONFIRMED
Both URLs return HTTP 200:
- `linux-nvidia-6.17_6.17.0.orig.tar.gz` (redirects via 303, serves correctly)
- `linux-nvidia-6.17_6.17.0-1012.12.diff.gz` (same)

The orig tarball extracts to `linux-6.17/` (NOT `linux-nvidia-6.17-6.17.0/`).

### `apply-nix-config.ts` against 6.17 NixOS config — FIXED
The 6.17 config uses a different Nix syntax than the parser expected:
- Option names are unquoted (`ACPI_DOCK`) or quoted when starting with digits (`"6LOWPAN_FOO"`)
- Values use `lib.kernel` identifiers: `yes`, `no`, `module`, `(freeform "value")`
- Previous parser expected `CONFIG_` prefix and quoted string values

Parser rewritten to handle both quoted/unquoted names and all 4 value types.
Verified: 2,402 options parsed (932 yes, 1,100 module, 314 no, 56 freeform), 0 failures.

### PKGBUILD version sync — FIXED
PKGBUILD no longer hardcodes version numbers. `gen-config.sh` writes
`configs/version.env` with `_kernelver`, `_ubuntupkg`, and `_kver_series`.
PKGBUILD sources this file. All `linux-nvidia-6.14` references replaced with
variables derived from `_kver_series`. Source directory now uses `_srcname=linux-${_kver_series}`.

---

### Full end-to-end build — CONFIRMED
`./build.sh` produces two packages:
- `linux-dgx-spark-6.17.0.1012_12-1-aarch64.pkg.tar.xz` (31 MB, 146 MB installed)
- `linux-dgx-spark-headers-6.17.0.1012_12-1-aarch64.pkg.tar.xz` (22 MB, 107 MB installed)

Kernel version: `6.17.9-dgx-spark`. 2,389 modules including `mlx5_core`,
`r8152`, Tegra/Grace SoC, and mt76 WiFi drivers. `.SRCINFO` generated.

---

## Remaining verification needed

### Boot test on DGX Spark
Install the produced package on the Spark, run `mkinitcpio -P`,
`grub-mkconfig -o /boot/grub/grub.cfg`, reboot, and verify:
- ConnectX-7 Ethernet comes up
- GPU is visible (`nvidia-smi`)
- No hard lockups under load

### Asus Ascent GX10 compatibility
The Ascent GX10 uses the same GB10 silicon. Worth testing once the Spark
build is stable.
