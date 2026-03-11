#!/usr/bin/env bash
# gen-config.sh
#
# Generates configs/config.aarch64 by:
#   1. Reading NVIDIA's validated config delta from nixos-dgx-spark
#   2. Auto-detecting the required kernel version from the config filename
#   3. Using the kernel source (pre-downloaded or fetched from Launchpad)
#   4. Starting from defconfig and applying the delta
#
# Usage:
#   ./scripts/gen-config.sh                        # downloads everything itself
#   ./scripts/gen-config.sh --cache-dir ./cache    # uses pre-downloaded sources
#
# Prerequisites (in your Arch aarch64 container):
#   pacman -S git bc libelf pahole
#   bun (installed via https://bun.sh/install)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
OUTPUT="${REPO_ROOT}/configs/config.aarch64"

# Parse --cache-dir flag
CACHE_DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cache-dir) CACHE_DIR="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# ── Step 1: Get nixos-dgx-spark config ───────────────────────────────────────

if [[ -n "$CACHE_DIR" && -d "${CACHE_DIR}/nixos-dgx-spark" ]]; then
  echo "==> Using cached nixos-dgx-spark from ${CACHE_DIR}"
  NIX_REPO_DIR="${CACHE_DIR}/nixos-dgx-spark"
else
  echo "==> Cloning nixos-dgx-spark to read validated config delta..."
  git clone --depth=1 https://github.com/graham33/nixos-dgx-spark "${WORK_DIR}/nixos-dgx-spark"
  NIX_REPO_DIR="${WORK_DIR}/nixos-dgx-spark"
fi

NIX_CONFIG=$(find "${NIX_REPO_DIR}/kernel-configs" \
  \( -name "nvidia-dgx-spark-*.config" -o -name "nvidia-dgx-spark-*.nix" \) \
  | sort -V | tail -1)

if [[ -z "$NIX_CONFIG" ]]; then
  echo "ERROR: Could not find generated kernel config in kernel-configs/"
  echo "Files found:"
  ls "${NIX_REPO_DIR}/kernel-configs/"
  exit 1
fi

echo "==> Found NixOS config: $NIX_CONFIG"

# ── Step 2: Extract version from filename ────────────────────────────────────

_basename=$(basename "$NIX_CONFIG")           # nvidia-dgx-spark-6.17.1.nix
_stripped="${_basename#nvidia-dgx-spark-}"    # 6.17.1.nix
KVER_FULL="${_stripped%.*}"                   # 6.17.1
KVER_SERIES="${KVER_FULL%.*}"                # 6.17
LAUNCHPAD_PKG="linux-nvidia-${KVER_SERIES}"

echo "==> Kernel version: ${KVER_FULL}, Launchpad package: ${LAUNCHPAD_PKG}"

# ── Step 3: Get kernel source ────────────────────────────────────────────────

# Find the orig tarball — either from cache or by downloading
ORIG_TAR=$(find "${CACHE_DIR:-.}" -maxdepth 1 -name "${LAUNCHPAD_PKG}_*.orig.tar.gz" 2>/dev/null | head -1)
DIFF_GZ=$(find "${CACHE_DIR:-.}" -maxdepth 1 -name "${LAUNCHPAD_PKG}_*.diff.gz" 2>/dev/null | head -1)

if [[ -n "$ORIG_TAR" && -n "$DIFF_GZ" ]]; then
  echo "==> Using cached sources:"
  echo "    orig: $(basename "$ORIG_TAR")"
  echo "    diff: $(basename "$DIFF_GZ")"

  # Extract version from cached filename for version.env
  # linux-nvidia-6.17_6.17.0.orig.tar.gz -> 6.17.0
  local_basename=$(basename "$ORIG_TAR")
  KERNEL_VER="${local_basename#${LAUNCHPAD_PKG}_}"
  KERNEL_VER="${KERNEL_VER%.orig.tar.gz}"

  local_diff=$(basename "$DIFF_GZ")
  # linux-nvidia-6.17_6.17.0-1012.12.diff.gz -> 1012.12
  PKG_VERSION="${local_diff#${LAUNCHPAD_PKG}_}"
  PKG_VERSION="${PKG_VERSION%.diff.gz}"
  UBUNTU_PKG="${PKG_VERSION##*-}"
else
  echo "==> Querying Launchpad for latest published source version..."
  LP_API="https://api.launchpad.net/1.0/ubuntu/+archive/primary"
  LP_API="${LP_API}?ws.op=getPublishedSources"
  LP_API="${LP_API}&source_name=${LAUNCHPAD_PKG}"
  LP_API="${LP_API}&exact_match=true"
  LP_API="${LP_API}&order_by_date=true"
  LP_API="${LP_API}&ws.size=1"

  LP_JSON=$(curl -fL --retry 3 --retry-delay 5 --max-time 60 "$LP_API")
  [[ -z "$LP_JSON" ]] && { echo "ERROR: Empty Launchpad API response"; exit 1; }

  PKG_VERSION=$(echo "$LP_JSON" \
    | grep -o '"source_package_version": "[^"]*"' \
    | head -1 \
    | sed 's/"source_package_version": "//; s/"//') || true
  [[ -z "$PKG_VERSION" ]] && { echo "ERROR: Could not parse version"; echo "$LP_JSON"; exit 1; }

  KERNEL_VER="${PKG_VERSION%%-*}"
  UBUNTU_PKG="${PKG_VERSION##*-}"

  echo "==> Launchpad package version: ${PKG_VERSION}"

  ORIG_TAR="${WORK_DIR}/${LAUNCHPAD_PKG}_${KERNEL_VER}.orig.tar.gz"
  DIFF_GZ="${WORK_DIR}/${LAUNCHPAD_PKG}_${KERNEL_VER}-${UBUNTU_PKG}.diff.gz"
  LAUNCHPAD_BASE="https://launchpad.net/ubuntu/+archive/primary/+sourcefiles/${LAUNCHPAD_PKG}/${PKG_VERSION}"

  echo "==> Fetching kernel source from Launchpad..."
  curl -fL --retry 3 --retry-delay 5 -o "$ORIG_TAR" "${LAUNCHPAD_BASE}/$(basename "$ORIG_TAR")"
  curl -fL --retry 3 --retry-delay 5 -o "$DIFF_GZ"  "${LAUNCHPAD_BASE}/$(basename "$DIFF_GZ")"
fi

# ── Step 4: Extract and patch ────────────────────────────────────────────────

echo "==> Extracting kernel source..."
tar xf "$ORIG_TAR" -C "$WORK_DIR"

KSRC=$(find "$WORK_DIR" -mindepth 1 -maxdepth 1 -type d ! -name nixos-dgx-spark | head -1)
if [[ -z "$KSRC" ]]; then
  echo "ERROR: Could not find extracted kernel source directory"
  ls "$WORK_DIR"
  exit 1
fi
echo "==> Kernel source directory: $(basename "$KSRC")"

cd "$KSRC"

echo "==> Removing files the diff will recreate (avoids duplicate definitions)..."
gzip -dc "$DIFF_GZ" | grep -B2 '^@@ -0,0 ' \
  | grep '^+++ ' \
  | sed 's|^+++ [^/]*/||; s/[[:space:]].*//' \
  | sort -u \
  | while read -r f; do
      [[ -n "$f" && -f "$f" ]] && echo "  removing pre-existing: $f" && rm -f "$f"
    done

echo "==> Applying Debian patch..."
gzip -dc "$DIFF_GZ" | patch -Np1 --forward || true

# ── Step 5: Build config ────────────────────────────────────────────────────

echo "==> Building baseline aarch64 defconfig..."
make ARCH=arm64 defconfig

echo "==> Parsing NixOS config delta and applying overrides..."
bun "${SCRIPT_DIR}/apply-nix-config.ts" \
  --nix-config "$NIX_CONFIG" \
  --kernel-src "$KSRC"

echo "==> Running olddefconfig to validate..."
make ARCH=arm64 olddefconfig

echo "==> Copying final config to ${OUTPUT}..."
cp .config "$OUTPUT"

# ── Step 6: Write version metadata ──────────────────────────────────────────

VERSION_ENV="${REPO_ROOT}/configs/version.env"
cat > "$VERSION_ENV" <<EOF
# Auto-generated by gen-config.sh — do not edit
_kernelver=${KERNEL_VER}
_ubuntupkg=${UBUNTU_PKG}
_kver_series=${KVER_SERIES}
EOF
echo "==> Wrote version metadata to configs/version.env"

echo ""
echo "Done! Review the config at: configs/config.aarch64"
echo "Key things to verify:"
echo "  grep -E 'MLX5|R8152|MT7925|TEGRA|NVGPU|GRACE' configs/config.aarch64"
