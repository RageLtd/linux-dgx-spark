# Build environment for linux-dgx-spark
# Forces arm64 platform so Apple Silicon runs this natively without emulation.
#
# Build:
#   docker build --platform linux/arm64 -t dgx-spark-builder .
#
# Run (mounts repo into container):
#   docker run --platform linux/arm64 --rm -it -v "$(pwd)":/build -w /build dgx-spark-builder bash
#
# Then inside the container:
#   ./scripts/gen-config.sh        # generate configs/config.aarch64
#   makepkg -s --noconfirm         # build the kernel packages

FROM menci/archlinuxarm:latest

# Fix pacman for Docker:
#  - DisableSandbox: Landlock sandboxing fails without kernel caps in containers
#  - CheckSpace disabled: Docker mounts /etc/resolv.conf read-only, breaking disk check
RUN sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf && \
    sed -i 's/^CheckSpace/#CheckSpace/' /etc/pacman.conf

# Pacman keyring init + full system update + base-devel group
# (menci/archlinuxarm is a minimal image — base-devel not pre-installed)
RUN pacman-key --init && \
    pacman-key --populate archlinuxarm && \
    pacman -Syu --noconfirm && \
    pacman -S --noconfirm --needed base-devel

# Kernel build dependencies + tooling
# Note: bun is AUR-only, installed separately below via official install script
RUN pacman -S --noconfirm --needed \
      bc \
      cpio \
      curl \
      gettext \
      git \
      libelf \
      pahole \
      patch \
      perl \
      python \
      tar \
      unzip \
      xz \
      zstd \
    && pacman -Scc --noconfirm

# Create a non-root build user (makepkg refuses to run as root)
RUN useradd -m -G wheel builder && \
    echo '%wheel ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers

# Install bun as the builder user via the official install script
USER builder
RUN curl -fsSL https://bun.sh/install | bash

# Make bun available on PATH for subsequent RUN steps and interactive shells
ENV PATH="/home/builder/.bun/bin:${PATH}"

WORKDIR /build

CMD ["bash"]
