# Qt build and capture toolchain for the second build host (oci2, arm64).
# openSUSE Tumbleweed ships the same Qt (6.12.0) and KWin (6.8.2) as lin1 (CachyOS) on 2026-11-14.
# Rolling base: a rebuild picks up newer packages, so check `qtpaths6 --qt-version` after one.
# Build on oci2: docker build --build-arg UID=$(id -u) --build-arg GID=$(id -g) -t switch-qt:tw /mnt/sdb/data/switch/qt
FROM opensuse/tumbleweed:latest

# No qt6-qmlcompiler-private-devel (qmlsc, GPL-only): the configure step fails if it is visible.
# Noto Sans and Noto Sans Mono: the same fontconfig fallbacks as lin1 ("monospace" text).
RUN zypper --non-interactive refresh \
 && zypper --non-interactive install --no-recommends \
      cmake ninja gcc-c++ \
      qt6-base-devel qt6-base-private-devel qt6-gui-private-devel qt6-widgets-devel qt6-test-devel \
      qt6-declarative-devel qt6-declarative-tools qt6-declarative-imports \
      qt6-wayland \
      kwin6 dbus-1 Mesa-dri Mesa-libEGL1 \
      fontconfig google-noto-sans-fonts google-noto-sans-mono-fonts \
      ImageMagick util-linux coreutils procps findutils \
 && zypper --non-interactive clean --all \
 && rm -rf /var/log/zypp* /var/cache/zypp

# kwin_wayland carries the cap_sys_nice file capability, which Docker's default set lacks, so exec
# fails with "Operation not permitted". Drop it; the headless capture does not need realtime priority.
RUN zypper --non-interactive install --no-recommends libcap-progs \
 && setcap -r /usr/bin/kwin_wayland \
 && zypper --non-interactive clean --all

# dbus-daemon refuses a UID with no passwd entry: name the host user who runs the container.
ARG UID=1002
ARG GID=1002
RUN echo "builder:x:${GID}:" >> /etc/group && echo "builder:x:${UID}:${GID}::/tmp:/bin/bash" >> /etc/passwd

# Qt logs to journald when stderr is not a terminal; the container has none, so QML errors would vanish.
ENV XDG_RUNTIME_DIR=/tmp/xdg QT_QPA_PLATFORM=wayland QT_FORCE_STDERR_LOGGING=1 LANG=C.UTF-8
WORKDIR /work
