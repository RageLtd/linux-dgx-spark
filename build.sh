#!/usr/bin/env bash
# build.sh — End-to-end kernel build for linux-dgx-spark
#
# Downloads sources on the host (reliable networking), then runs the kernel
# config generation and package build inside a native aarch64 container.
#
# Usage:
#   ./build.sh              # full build (download + container + config + packages)
#   ./build.sh download     # only download sources to cache/
#   ./build.sh config       # download + container + generate configs/config.aarch64
#   ./build.sh pkg          # only run makepkg (config must already exist)
#
# Prerequisites: Docker (with linux/arm64 support, e.g. Apple Silicon)

set -euo pipefail

IMAGE_NAME="dgx-spark-builder"
PLATFORM="linux/arm64"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="${REPO_DIR}/cache"

# ── Helpers ──────────────────────────────────────────────────────────────────

log()  { echo "==> $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

docker_run() {
  docker run \
    --platform "$PLATFORM" \
    --rm \
    -e HOST_UID="$HOST_UID" \
    -e HOST_GID="$HOST_GID" \
    -v "${REPO_DIR}":/build \
    -v dgx-spark-builddir:/tmp/makepkg \
    -w /build \
    "$IMAGE_NAME" \
    bash -lc "$1"
}

# ── Steps ────────────────────────────────────────────────────────────────────

download_sources() {
  mkdir -p "$CACHE_DIR"

  # 1. Clone nixos-dgx-spark (if not already cached)
  if [[ ! -d "${CACHE_DIR}/nixos-dgx-spark" ]]; then
    log "Cloning nixos-dgx-spark..."
    git clone --depth=1 https://github.com/graham33/nixos-dgx-spark "${CACHE_DIR}/nixos-dgx-spark"
  else
    log "Using cached nixos-dgx-spark (delete cache/nixos-dgx-spark to refresh)"
  fi

  # 2. Find the config and extract version info
  local nix_config
  nix_config=$(find "${CACHE_DIR}/nixos-dgx-spark/kernel-configs" \
    \( -name "nvidia-dgx-spark-*.config" -o -name "nvidia-dgx-spark-*.nix" \) \
    | sort -V | tail -1)

  if [[ -z "$nix_config" ]]; then
    die "Could not find kernel config in nixos-dgx-spark/kernel-configs/"
  fi
  log "Found NixOS config: $(basename "$nix_config")"

  local _basename _stripped
  _basename=$(basename "$nix_config")
  _stripped="${_basename#nvidia-dgx-spark-}"
  local kver_full="${_stripped%.*}"
  local kver_series="${kver_full%.*}"
  local launchpad_pkg="linux-nvidia-${kver_series}"

  log "Kernel version: ${kver_full}, Launchpad package: ${launchpad_pkg}"

  # 3. Query Launchpad API
  log "Querying Launchpad for latest published source version..."
  local lp_api="https://api.launchpad.net/1.0/ubuntu/+archive/primary"
  lp_api="${lp_api}?ws.op=getPublishedSources"
  lp_api="${lp_api}&source_name=${launchpad_pkg}"
  lp_api="${lp_api}&exact_match=true"
  lp_api="${lp_api}&order_by_date=true"
  lp_api="${lp_api}&ws.size=1"

  local lp_json
  lp_json=$(curl -fL --retry 3 --retry-delay 5 --max-time 60 "$lp_api")
  [[ -z "$lp_json" ]] && die "Empty response from Launchpad API"

  local pkg_version
  pkg_version=$(echo "$lp_json" \
    | grep -o '"source_package_version": "[^"]*"' \
    | head -1 \
    | sed 's/"source_package_version": "//; s/"//') || true
  [[ -z "$pkg_version" ]] && die "Could not parse source_package_version from Launchpad"

  local kernel_ver="${pkg_version%%-*}"
  local ubuntu_pkg="${pkg_version##*-}"
  log "Launchpad version: ${pkg_version} (kernel=${kernel_ver}, ubuntu=${ubuntu_pkg})"

  # 4. Download orig tarball + diff
  local orig_tar="${launchpad_pkg}_${kernel_ver}.orig.tar.gz"
  local diff_gz="${launchpad_pkg}_${kernel_ver}-${ubuntu_pkg}.diff.gz"
  local base_url="https://launchpad.net/ubuntu/+archive/primary/+sourcefiles/${launchpad_pkg}/${pkg_version}"

  if [[ ! -f "${CACHE_DIR}/${orig_tar}" ]]; then
    log "Downloading ${orig_tar}..."
    curl -fL --retry 3 --retry-delay 5 -o "${CACHE_DIR}/${orig_tar}" "${base_url}/${orig_tar}"
  else
    log "Using cached ${orig_tar}"
  fi

  if [[ ! -f "${CACHE_DIR}/${diff_gz}" ]]; then
    log "Downloading ${diff_gz}..."
    curl -fL --retry 3 --retry-delay 5 -o "${CACHE_DIR}/${diff_gz}" "${base_url}/${diff_gz}"
  else
    log "Using cached ${diff_gz}"
  fi

  log "All sources ready in cache/"
}

build_container() {
  log "Building container image: ${IMAGE_NAME}"
  docker build --platform "$PLATFORM" -t "$IMAGE_NAME" "$REPO_DIR"
}

gen_config() {
  if [[ ! -d "${CACHE_DIR}/nixos-dgx-spark" ]]; then
    die "cache/ not populated — run './build.sh download' first"
  fi
  log "Generating kernel config (configs/config.aarch64)..."
  docker_run "
    bash ./scripts/gen-config.sh --cache-dir /build/cache
    chown \${HOST_UID}:\${HOST_GID} /build/configs/config.aarch64 /build/configs/version.env 2>/dev/null || true
  "
  log "Config written to configs/config.aarch64"
}

build_packages() {
  if [[ ! -f "${REPO_DIR}/configs/config.aarch64" ]]; then
    die "configs/config.aarch64 not found — run './build.sh config' first"
  fi

  # Source version metadata to locate the source tree
  source "${REPO_DIR}/configs/version.env"
  local _srcver="linux-${_kver_series}"
  local _prepared="/tmp/makepkg/linux-dgx-spark/src/${_srcver}/version"

  # SRCDEST: keep downloaded sources on the bind mount (cache-friendly, no re-download)
  # BUILDDIR: extract + compile on container-local ext4 (case-sensitive — macOS
  # can't handle xt_HL.c vs xt_hl.c coexisting in the same directory)
  #
  # If the source tree is already prepared (version file exists from a previous
  # prepare()), skip extraction with -e for fast incremental rebuilds.
  # To force a clean build: docker volume rm dgx-spark-builddir
  docker_run "
    sudo chown -R builder:builder /build /tmp/makepkg
    if [[ -f ${_prepared} ]]; then
      echo '==> Source tree already prepared, incremental build (-e)'
      SRCDEST=/build/cache BUILDDIR=/tmp/makepkg makepkg -e -s --noconfirm
    else
      echo '==> Fresh build (extract + prepare + build)'
      SRCDEST=/build/cache BUILDDIR=/tmp/makepkg makepkg -s --noconfirm
    fi
    cp /tmp/makepkg/*.pkg.tar.* /build/ 2>/dev/null || true
    sudo chown \${HOST_UID}:\${HOST_GID} /build/*.pkg.tar.* 2>/dev/null || true
  "
  log "Done! Packages:"
  ls -1 "${REPO_DIR}"/linux-dgx-spark-*.pkg.tar.* 2>/dev/null || echo "  (no packages found — check build output above)"
}

# ── Main ─────────────────────────────────────────────────────────────────────

cmd="${1:-all}"

case "$cmd" in
  download)
    download_sources
    ;;
  config)
    download_sources
    build_container
    gen_config
    ;;
  pkg)
    build_container
    build_packages
    ;;
  all)
    download_sources
    build_container
    gen_config
    build_packages
    ;;
  *)
    echo "Usage: $0 [all|config|pkg|download]"
    exit 1
    ;;
esac
