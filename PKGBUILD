# Maintainer: Your Name <your@email.com>
# Contributor: graham33 (nixos-dgx-spark)
#
# Kernel for NVIDIA DGX Spark (GB10 Grace-Blackwell)
# Sources NVIDIA's custom kernel from Launchpad
# Config derived from NVIDIA's Debian annotations, cross-referenced
# against the nixos-dgx-spark project.
#
# Build in a native aarch64 environment (e.g. Apple Silicon container).
# Run scripts/gen-config.sh first to generate configs/config.aarch64.

# Source version metadata written by gen-config.sh
# Provides: _kernelver, _ubuntupkg, _kver_series
_version_env="${startdir:-$(pwd)}/configs/version.env"
if [[ -f "$_version_env" ]]; then
  source "$_version_env"
else
  echo "ERROR: configs/version.env not found — run scripts/gen-config.sh first" >&2
  exit 1
fi

pkgbase=linux-dgx-spark
pkgname=("${pkgbase}" "${pkgbase}-headers")
pkgver=${_kernelver}.${_ubuntupkg//./_}
pkgrel=1
pkgdesc="Linux kernel for NVIDIA DGX Spark (GB10 Grace-Blackwell)"
arch=('aarch64')
url="https://launchpad.net/ubuntu/+source/linux-nvidia-${_kver_series}"
license=('GPL2')
makedepends=(
  'bc'
  'cpio'
  'gettext'
  'libelf'
  'pahole'
  'perl'
  'python'
  'tar'
  'xz'
  'zstd'
)
options=('!strip')

_launchpadpkg="linux-nvidia-${_kver_series}"
_srcname="linux-${_kver_series}"
_orig="${_launchpadpkg}_${_kernelver}.orig.tar.gz"
_diff="${_launchpadpkg}_${_kernelver}-${_ubuntupkg}.diff.gz"

# Source URLs — always use Launchpad for AUR compatibility.
# build.sh sets SRCDEST to use pre-downloaded cache files.
_launchpad_base="https://launchpad.net/ubuntu/+archive/primary/+sourcefiles/${_launchpadpkg}/${_kernelver}-${_ubuntupkg}"

source=(
  "${_launchpad_base}/${_orig}"
  "${_launchpad_base}/${_diff}"
)
sha256sums=('SKIP' 'SKIP')

prepare() {
  # Ensure the config was generated before building
  if [[ ! -f "${startdir}/configs/config.aarch64" ]]; then
    error "Missing configs/config.aarch64 - run scripts/gen-config.sh first"
    exit 1
  fi

  cd "${srcdir}/${_srcname}"

  # Apply the Ubuntu/NVIDIA debian patch series
  # The diff creates new files that may already exist in the upstream 6.17
  # tarball (e.g. pinctrl-mt8901.c, version_signature.c were merged upstream
  # but the Ubuntu diff still carries them). Remove such files first so the
  # diff can recreate them cleanly instead of appending duplicate content.
  local _difffile="../${_launchpadpkg}_${_kernelver}-${_ubuntupkg}.diff"
  echo "Removing files that the Ubuntu diff will recreate..."
  # dpkg-source diffs use .orig/ prefix (not /dev/null) for new files.
  # Detect them by @@ -0,0 hunks and grab the +++ path above each.
  grep -B2 '^@@ -0,0 ' "$_difffile" \
    | grep '^+++ ' \
    | sed 's|^+++ [^/]*/||; s/[[:space:]].*//' \
    | sort -u \
    | while read -r f; do
        if [[ -n "$f" && -f "$f" ]]; then
          echo "  removing pre-existing: $f"
          rm -f "$f"
        fi
      done || true

  echo "Applying Ubuntu NVIDIA kernel patches..."
  patch -Np1 --forward < "$_difffile" || true

  # Apply any DGX Spark specific patches from this repo
  local patchdir="${startdir}/patches"
  if [[ -d "$patchdir" ]]; then
    for p in "$patchdir"/*.patch; do
      [[ -f "$p" ]] || continue
      echo "Applying patch: $p"
      patch -Np1 < "$p"
    done
  fi

  # Install our assembled kernel config
  cp "${startdir}/configs/config.aarch64" .config

  # Set the local version string
  echo "-dgx-spark" > localversion.10-pkgname

  # Sync config with current kernel source
  make olddefconfig
  diff -u "${startdir}/configs/config.aarch64" .config || :

  # Write version file for packaging (used by $(<version) in package functions)
  make -s kernelrelease > version
  echo "Prepared kernel version: $(<version)"
}

build() {
  cd "${srcdir}/${_srcname}"

  # Build kernel image + modules only — skip DTBs (DGX Spark uses ACPI, not device trees)
  # Use image_name to get the correct target (Image.gz when gzip compression is configured)
  make -j"$(nproc)" "$(basename "$(make -s image_name)")" modules
}

_package() {
  pkgdesc="The ${pkgdesc} kernel and modules"
  depends=('coreutils' 'kmod' 'initramfs')
  optdepends=(
    'wireless-regdb: to set the correct wireless channels of your country'
    'linux-firmware: firmware images needed for some devices'
  )
  provides=("linux=${pkgver}")

  cd "${srcdir}/${_srcname}"

  local kernver="$(<version)"
  local modulesdir="${pkgdir}/usr/lib/modules/${kernver}"

  echo "Installing boot image..."
  install -Dm644 "$(make -s image_name)" "${modulesdir}/vmlinuz"
  echo "${pkgbase}" | install -Dm644 /dev/stdin "${modulesdir}/pkgbase"

  echo "Installing modules..."
  make INSTALL_MOD_PATH="${pkgdir}/usr" INSTALL_MOD_STRIP=1 \
    DEPMOD=/doesnt/exist modules_install

  # Remove build and source symlinks - headers package will handle them
  rm -f "${modulesdir}/"{build,source}
}

_package-headers() {
  pkgdesc="Headers and scripts for building modules for the ${pkgdesc} kernel"
  depends=("${pkgbase}=${pkgver}")
  provides=("linux-headers=${pkgver}")

  cd "${srcdir}/${_srcname}"

  local builddir="${pkgdir}/usr/lib/modules/$(<version)/build"

  echo "Installing build files..."
  install -Dt "${builddir}" -m644 .config Makefile Module.symvers \
    System.map localversion.10-pkgname vmlinux
  install -Dt "${builddir}/kernel" -m644 kernel/Makefile
  install -Dt "${builddir}/arch/arm64" -m644 arch/arm64/Makefile
  cp -t "${builddir}" -a scripts

  echo "Installing headers..."
  cp -t "${builddir}" -a include
  cp -t "${builddir}/arch/arm64" -a arch/arm64/include
  install -Dt "${builddir}/arch/arm64/kernel" -m644 \
    arch/arm64/kernel/asm-offsets.s

  install -Dt "${builddir}/drivers/md" -m644 drivers/md/*.h
  install -Dt "${builddir}/net/mac80211" -m644 net/mac80211/*.h
  install -Dt "${builddir}/drivers/media/i2c" -m644 \
    drivers/media/i2c/msp3400-driver.h
  install -Dt "${builddir}/drivers/media/usb/dvb-usb" -m644 \
    drivers/media/usb/dvb-usb/*.h
  install -Dt "${builddir}/drivers/media/dvb-frontends" -m644 \
    drivers/media/dvb-frontends/*.h
  install -Dt "${builddir}/drivers/media/tuners" -m644 \
    drivers/media/tuners/*.h
  install -Dt "${builddir}/drivers/iio" -m644 drivers/iio/*.h

  echo "Installing KConfig files..."
  find . -name 'Kconfig*' -exec install -Dm644 {} "${builddir}/{}" \;

  echo "Removing unneeded architectures..."
  local arch
  for arch in "${builddir}"/arch/*/; do
    [[ "${arch}" = */arm64/ ]] && continue
    echo "Removing $(basename "${arch}")"
    rm -r "${arch}"
  done

  echo "Removing broken symlinks..."
  find -L "${builddir}" -type l -printf 'Removing %P\n' -delete

  echo "Removing loose objects..."
  find "${builddir}" -type f -name '*.o' -printf 'Removing %P\n' -delete

  echo "Stripping build tools..."
  while read -rd '' file; do
    case "$(file -Sib "$file")" in
      application/x-sharedlib\;*)
        strip -v "${STRIP_SHARED}" "$file" ;;
      application/x-archive\;*)
        strip -v "${STRIP_STATIC}" "$file" ;;
      application/x-executable\;*)
        strip -v "${STRIP_BINARIES}" "$file" ;;
      application/x-pie-executable\;*)
        strip -v "${STRIP_SHARED}" "$file" ;;
    esac
  done < <(find "${builddir}" -type f -perm -u+x ! -name vmlinux -print0)

  echo "Stripping vmlinux..."
  strip -v "${STRIP_STATIC}" "${builddir}/vmlinux"

  echo "Adding symlink..."
  mkdir -p "${pkgdir}/usr/src"
  ln -sr "${builddir}" "${pkgdir}/usr/src/${pkgbase}"
}

for _p in "${pkgname[@]}"; do
  eval "package_${_p}() {
    $(declare -f "_package${_p#${pkgbase}}")
    _package${_p#${pkgbase}}
  }"
done
