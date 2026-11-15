# Linux package

One self-contained app folder, shipped as a `tar.gz` and an AppImage. It holds the Qt app, the
`switch-core` helper, every Qt and Swift library they load, and the license notices.

## Build

The builder image is Ubuntu 24.04 (glibc 2.39) with the official Qt binaries (`Dockerfile`). The
Tumbleweed image in `scripts/oci` cannot build the package: its Qt needs glibc 2.43, so the app would
not start on Ubuntu 24.04 or Fedora 42.

```sh
# on oci2 (arm64) or any x86_64 host; the image follows the host architecture
docker build -t switch-pkg:noble packages/qt-gui/packaging/linux
docker run --rm --user $(id -u):$(id -g) -e HOME=/tmp -v <work>:/w -v <switch-core folder>:/opt/helper:ro \
  switch-pkg:noble bash /w/src/packaging/linux/build-package.sh /w/src /w/out /opt/helper /w/AppIcon.png
```

- `<work>/src` is a copy of `packages/qt-gui`. `AppIcon.png` is the 1024 px Mac icon
  (`packages/mac-gui/Resources/Icons/AppIcon.png`).
- The `switch-core` folder is a release build with its Swift runtime libraries in `lib/`.
- Output in `<work>/out`: `Switch/` (the app folder), `Switch-<version>-linux-<arch>.tar.gz`,
  `Switch-<version>-linux-<arch>.AppImage`, `host-libs.txt` and `qml-imports.json`.

The desktop entry and the hicolor icons are named by the app id, `com.mandalsuraj.Switch`
(`kAppId` in `src/globalshortcut.cpp`): the GlobalShortcuts portal matches the id to an installed
entry, and GLib skips an entry whose `Exec` program it cannot find. The template says
`Exec=switch-app` (the `.deb`/`.rpm` link below). From the tar.gz, `./install.sh` puts the entry in
`~/.local/share/applications` with `Exec` set to the absolute `bin/switch`, the icons in
`~/.local/share/icons/hicolor`, and a `~/.local/bin/switch-app` link; `./install.sh --remove` undoes it.
The AppImage embeds the same entry and icon at its top level. AppImage integration tools rename the
entry (such as `appimagekit_<hash>-com.mandalsuraj.Switch.desktop`), which the portal does not
match, so the app writes its own `~/.local/share/applications/com.mandalsuraj.Switch.desktop` with
`Exec="$APPIMAGE"` at start and rewrites it when the AppImage moves (`GlobalShortcut::writeAppImageEntry`).

The script finds the dependencies with tools: `qmlimportscanner` for the QML modules, then `ldd` on
every ELF file until no new library from the Qt prefix appears. Every ELF file gets a `RUNPATH` of
`$ORIGIN/<path to lib>` (`patchelf`); there is no `LD_LIBRARY_PATH` wrapper. `bin/qt.conf` points Qt at
`plugins/` and `qml/`.

## Check on a clean host

`check-package.sh <app folder> [capture dir]` runs inside a plain distro container with no Qt and no
Swift. It lists the libraries the host lacks, runs `switch-core doctor` and `serve` (initialize), and
starts the app in `--demo` on the offscreen platform. With a harness build as `bin/switch` and a
capture folder, it captures the Settings page.

Results (arm64, Qt 6.12.0, app 0.1.0):

| Host | Libraries missing | doctor | serve initialize | app `--demo` |
|---|---|---|---|---|
| Ubuntu 24.04.5, glibc 2.39, bare | GL, X11/xcb, Wayland, fontconfig, dbus, glib, curl, sqlite | cannot load (libsqlite3) | cannot load | cannot load (libEGL) |
| Fedora 45, glibc 2.44, bare | GL, X11/xcb, Wayland, fontconfig, dbus | all checks passed | result | cannot load (libEGL) |
| Ubuntu 24.04.5 with desktop libraries | none | all checks passed | result | runs; Settings capture with the harness build |
| Fedora 45 with desktop libraries | none | all checks passed | result | runs |

A desktop install has every one of these libraries. On Fedora the system `libcurl` prints "no version
information available" for `libFoundationNetworking.so`; that warning is harmless.

Host libraries the package needs (`host-libs.txt`): glibc (`libc`, `libm`, `libdl`, `libpthread`,
the loader), `libstdc++`, `libgcc_s`, `libGL`, `libEGL`, `libX11`, `libX11-xcb`, `libxcb` with
`-cursor -glx -icccm -image -keysyms -randr -render -render-util -shape -shm -sync -xfixes -xkb`,
`libxkbcommon`, `libxkbcommon-x11`, `libSM`, `libICE`, `libwayland-client -cursor -egl`,
`libfontconfig`, `libfreetype`, `libdbus-1`, `libglib-2.0`, `libz`, `libzstd`, `libbrotlidec`
(Qt), and `libcurl`, `libsqlite3` (`switch-core`). The oldest supported host is glibc 2.39 with
GLIBCXX 3.4.32 (Ubuntu 24.04, Fedora 40, Debian 13).

Sizes (MB): app folder 219 = Qt 65 (libraries, plugins, QML) + Qt ICU 38 + Swift 53 (`switch-core`
is 15 of it) + Swift ICU 39 + the app binary and the rest. AppImage 67, tar.gz 73. Quick Controls
come in only through `QtQuick.Dialogs` (the non-native folder dialog); the app selects the Basic style
(`main.cpp`), so the package keeps only Basic. The other styles were 23 MB of the folder.

ICU data, not applied:
- Qt ICU (`libicudata.so.73`, about 30 MB of the 38): Qt uses ICU for collation, locale names,
  text boundaries and codecs. Saving: about 25-30 MB with an ICU data filter (keep `en` plus the root
  break rules) or a Qt build with `-no-icu`. Risk: we build and ship our own Qt; sorting and word
  breaks for other languages change; Qt falls back to its own simpler code without ICU.
- Swift ICU (`lib_FoundationICU.so`, 39 MB): the data is compiled into the library. Saving: about
  30 MB with a filtered `swift-foundation-icu` build. Risk: a custom Swift toolchain library; date,
  number and list formatting in `switch-core` fall back to root-locale rules for languages left out.
- Recommendation: keep both until the app is translated. Then filter both to the shipped languages
  in one step, and test date and number text per language.

## LGPL compliance

- Qt is linked dynamically. `libQt6*.so.6` sit in `lib/`, plugins in `plugins/`, QML modules in `qml/`.
  To use another Qt 6.12 build, replace those files (or point `bin/qt.conf` at another prefix). The
  app binary looks them up only through its `RUNPATH` (`$ORIGIN/../lib`) and `qt.conf`. For the
  AppImage, run it with `--appimage-extract`, replace the files, and run `AppRun` from the folder.
- Notices in `share/licenses/switch/`: `Qt-LGPL-3.0.txt` and `GPL-3.0.txt` (LGPL v3 is a set of
  extra terms on the GPL v3 text), `Qt-NOTICES.txt` (every shipped Qt file with its module and
  license, the source offer, and the notices of the third-party code inside Qt from
  `qt_attribution.json`), `Swift-LICENSE.txt` (Apache 2.0 with the Runtime Library Exception),
  `ICU-LICENSE.txt` (Unicode v3, for Qt's ICU and Swift's `_FoundationICU`), `Inter-OFL-1.1.txt`,
  `JetBrainsMono-OFL-1.1.txt`, and `provider-marks.md`.
- Source offer: `Qt-NOTICES.txt` links the exact `-everywhere-src-<version>` archives on
  download.qt.io and the `v<version>` git tag, and offers the sources on request for three years.
- No GPL-only Qt code: the app links Core, Gui, Qml, Quick, Widgets (plus OpenGL, Network, DBus
  through them), and loads QML modules from Qt Declarative only. `qmlcachegen` compiles the QML;
  `qmlsc` never runs (CMake guard). `build-package.sh` fails if a Charts, Graphs, Quick 3D, Shader
  Tools, Quick Timeline, Data Visualization, Virtual Keyboard or Wayland Compositor file is in the folder.

Shipped third-party parts and licenses (the full file list is in `Qt-NOTICES.txt`):

| Part | Files | License |
|---|---|---|
| Qt Base | Core, Gui, Widgets, OpenGL, Network, DBus, XcbQpa; xcb, offscreen, input-context, portal-theme plugins | LGPL-3.0-only |
| Qt Declarative | Qml, QmlCore, QmlMeta, QmlModels, QmlWorkerScript, Quick, QuickControls2 (+ styles), QuickTemplates2, QuickDialogs2, QuickLayouts, QuickShapes, QuickEffects, LabsFolderListModel; `qml/` modules | LGPL-3.0-only |
| Qt SVG | Svg; SVG image and icon plugins | LGPL-3.0-only |
| Qt Wayland | WaylandClient; Wayland platform, xdg-shell, decoration and EGL plugins | LGPL-3.0-only |
| ICU 73 (in Qt), `_FoundationICU` (in Swift) | `libicu*.so.73`, `lib_FoundationICU.so` | Unicode-3.0 |
| Swift runtime and Foundation | `libswift*`, `libFoundation*`, `libdispatch`, `libBlocksRuntime` | Apache-2.0 with Runtime Library Exception |
| Inter, JetBrains Mono | built into the app binary | OFL-1.1 |
| Provider marks | built into the app binary | trademarks of their owners, see `provider-marks.md` |

## Other formats (plan)

**.deb and .rpm.** Ship the same folder under `/opt/switch` with a `/usr/share/applications` entry,
the hicolor icons, and a `/usr/bin/switch-app` link. Declare only the host libraries in
`host-libs.txt` as dependencies; keep Qt bundled. Distro Qt is too old on Ubuntu 24.04 (6.4) and
moves on its own schedule elsewhere, and the app uses private Qt API in harness builds and Qt 6.8+
QML. Recommendation: build both with `nfpm` from the app folder in the same container, one
config, no distro-specific Qt. Name the launcher `switch-app` or keep the binary under `/opt`, because
`switch` is the CLI command in `~/.local/bin`.

**Flatpak.** Runtime: the first `org.kde.Platform` branch that carries Qt 6.12 (KDE runtimes track Qt
closely); until then `org.freedesktop.Platform` with Qt built as a module in the manifest. File access:
the helper reads and writes tool folders such as `~/.codex`, `~/.claude`, `~/.factory` and its own
data root, so it needs `--filesystem=home` (or one `--filesystem=~/.codex:create` entry per tool).
The hard part is terminals: sign-in, Open <tool>, and Resume start a terminal and a host CLI. Inside the
sandbox, that needs `flatpak-spawn --host` with `--talk-name=org.freedesktop.Flatpak`, which is a full
sandbox escape and a review flag on Flathub. Recommendation: no Flatpak for now; it gives little
isolation once it has home access and host spawn. Revisit only for Flathub reach.

**x86_64.** lin1 is down. Options: GitHub Actions `ubuntu-24.04` runners (x86_64, free for a public
repo, the same Dockerfile runs as-is), or QEMU user emulation on oci2 (`docker run --platform
linux/amd64` with binfmt; about 5-10x slower, so a 2 min build takes 10-20 min, and it holds a CPU the
Qt workers use). Recommendation: GitHub Actions for the x86_64 package; the scripts follow
`uname -m`, so no change is needed. Keep oci2 for arm64.
