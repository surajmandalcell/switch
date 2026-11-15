# Linux package builder: Ubuntu 24.04 (glibc 2.39) with the official Qt binaries, so the package runs on
# Ubuntu 24.04, Fedora 40 and newer. The Tumbleweed image (scripts/oci) links glibc 2.43 and cannot be the base.
# Build on oci2 (arm64) or any x86_64 host:
#   docker build -t switch-pkg:noble packages/qt-gui/packaging/linux
FROM ubuntu:24.04

ARG QT_VERSION=6.12.0
ARG APPIMAGETOOL=1.9.0

# Compilers, the GL/xkb/fontconfig headers Qt's CMake config needs, patchelf for RUNPATHs,
# ImageMagick for the hicolor icons, the license texts in /usr/share/common-licenses, and the host
# libraries the shipped Qt plugins load (so ldd resolves them and host-libs.txt lists them).
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      build-essential cmake ninja-build python3-venv ca-certificates curl \
      libgl-dev libegl-dev libvulkan-dev libxkbcommon-dev libfontconfig-dev libfreetype-dev \
      patchelf file imagemagick base-files desktop-file-utils \
      libdbus-1-3 libwayland-cursor0 libwayland-egl1 libxkbcommon-x11-0 libsm6 libice6 \
      libxcb-cursor0 libxcb-icccm4 libxcb-image0 libxcb-keysyms1 libxcb-render-util0 libxcb-shape0 libxcb-xkb1 \
 && rm -rf /var/lib/apt/lists/*

# Official Qt (LGPL builds from download.qt.io) through aqtinstall. The architecture follows the image.
RUN python3 -m venv /opt/aqt \
 && /opt/aqt/bin/pip install --no-cache-dir aqtinstall \
 && case "$(uname -m)" in \
      aarch64) host=linux_arm64; arch=linux_gcc_arm64 ;; \
      *)       host=linux;       arch=linux_gcc_64 ;; \
    esac \
 && /opt/aqt/bin/aqt install-qt "$host" desktop "$QT_VERSION" "$arch" -O /opt/qt \
 && /opt/aqt/bin/aqt install-src "$host" desktop "$QT_VERSION" --archives qtbase qtdeclarative qtsvg qtwayland -O /opt/qt-src \
 && find /opt/qt-src -type f ! -name qt_attribution.json ! -path '*/LICENSES/*' ! -iname 'LICENSE*' ! -iname 'COPYING*' -delete \
 && ln -s /opt/qt/"$QT_VERSION"/* /opt/qt/current \
 && rm -rf /root/.cache

# appimagetool runs extracted, because containers have no FUSE.
RUN curl -fsSL -o /usr/local/bin/appimagetool \
      "https://github.com/AppImage/appimagetool/releases/download/$APPIMAGETOOL/appimagetool-$(uname -m).AppImage" \
 && chmod +x /usr/local/bin/appimagetool
ENV APPIMAGE_EXTRACT_AND_RUN=1 QT_PREFIX=/opt/qt/current LANG=C.UTF-8
