# Switch for Linux and Windows (Qt Quick)

The native Linux and Windows app. It must look and behave like the Mac app (`packages/mac-gui`); the
port specs in `specs/port/` are the source of truth, and the Mac captures are the visual reference.
All data comes from the `switch-core serve` helper over JSON-RPC (`specs/port/rpc.md`).

## Build and run on Linux

Needs Qt 6.8 or later (Core, Gui, Qml, Quick, Widgets; GuiPrivate for the harness; Test for the
test), CMake 3.21, Ninja and a C++20 compiler.

```sh
cmake -S packages/qt-gui -B <build dir> -G Ninja -DCMAKE_BUILD_TYPE=Release
ninja -C <build dir> -j 2
<build dir>/tst_helperclient                 # helper client test (uses a fake helper)
<build dir>/switch --demo                    # demo data, no helper
<build dir>/switch --helper /path/to/switch-core --root /tmp/switch-test
```

Without `--helper` the app starts `switch-core` from its own folder, never one from `PATH`.
`--root <dir>` gives the helper a private data root (`AI_MANAGER_ROOT=<dir>/switch`,
`HOME=<dir>/home`); automated runs always use it.

From the Mac, `scripts/remote.zsh [build|shots|all]` syncs this folder to the build host
(`lin1`), builds there under the Qt lock (`/mnt/nvme1/data/switch/port/qt.lock`; the Windows VM and the
`switch-core` Swift build use `build.lock`), captures, and compares (see Screenshots).

### Flags

| Flag | Effect |
|---|---|
| `--demo` | Feed every model from `assets/demo.json` instead of the helper |
| `--theme light\|dark\|system` | Override the system appearance (captures) |
| `--page <title>` | Open on a page (Overview, Accounts, Settings, Maintenance, History) |
| `--gallery` | Add the developer component gallery to the sidebar |
| `--no-motion` | Turn every animation off (captures) |
| `--content-only` | No window buttons, outline or corners, like a Mac content-view capture |
| `--update` | Show the "Update available" button (Settings capture) |
| `--background` | Start with the window hidden (tray only) |
| `--script shots --out <dir> [--pages a,b]` | Capture run (harness builds only) |

## Layout

```
CMakeLists.txt        build, license checks
src/                  C++: main, AppState (flags, keyboard mode, work area), HelperClient (JSON-RPC),
                      Tray (icon, menu, popover placement), Harness (captures, dev only)
qml/components/       design system: Theme (tokens) and one file per control
qml/shell/            Main window, Sidebar, PageHeader, TrafficLights, Driver (capture scripts)
qml/pages/            one file per page; PlaceholderPage names the spec of a page not built yet
qml/popover/          tray popover window, outline shape, rows, footer buttons
assets/               tray template mark, demo.json
fonts/                Inter (SIL OFL, fonts/LICENSE.txt); JetBrains Mono Regular 2.304 for code, paths
                      and IDs (SIL OFL, fonts/LICENSE-JetBrainsMono.txt)
tests/                tst_helperclient (the same binary is its own fake helper)
scripts/              build.sh, shots.sh (build host), compare.sh, remote.zsh (Mac)
```

The QML files sit in folders for people but form one flat module `SwitchUI` at run time, so any file
uses any component without an import. `Theme` is a singleton.

## Licensing

Switch links Qt under the LGPL v3. CMake enforces these rules and fails the configure step otherwise:

- Only LGPL Qt modules, linked dynamically (`Qt6::Core` must be a shared library).
- `qmlcachegen` is the only QML compiler. `QT_NO_FIND_QMLSC` keeps the GPL-only `qmlsc` out, the
  target pins `QT_QMLCACHEGEN_EXECUTABLE qmlcachegen`, and configure fails if `Qt6::qmlsc` exists.
- No Qt Graphs, Qt Charts, Quick 3D, Shader Tools, Quick Timeline, Data Visualization or Virtual
  Keyboard on any link line. Charts are our own QML (`Shape`, `Canvas`).
- No dependency beyond Qt. Bundled fonts: Inter and JetBrains Mono, both SIL OFL 1.1; ship their license files.

Linked Qt modules: Core, Gui, Qml, Quick, Widgets (tray menu), DBus (Linux only: the GlobalShortcuts
portal and desktop notifications), GuiPrivate (harness builds only), Test (test only). QML modules loaded at run time: QtQuick, QtQuick.Window, QtQuick.Shapes,
QtQuick.Effects (all part of Qt Declarative, LGPL). Image plugin loaded at run time: `qsvg` (Qt Svg, LGPL)
for the provider icons in `assets/providers/icon/`; a package must ship it. A shipping build sets `-DSWITCH_HARNESS=OFF
-DSWITCH_TESTS=OFF`.

## Adding a page

1. Read the page spec in `specs/port/` and the Mac capture.
2. Create `qml/pages/<Name>Page.qml`. Its root `Item` has `property alias header: header`, a
   `PageHeader { id: header }` on top and a `ScrollArea` below (see `SettingsPage.qml`).
   Build every control from `qml/components`; add a token to `Theme.qml` only when the spec names it.
3. In `qml/shell/Main.qml`, map the route to the new file name in the page `Loader` and drop the
   `spec` field of that page entry (that field makes it a placeholder). Pages, the popover and the Account
   window load by URL, so a file with an error shows "This page failed to load: <file>:<line>" in its own
   slot, logs it to stderr, and leaves the rest of the app working.
4. Read data from `Helper.topics.<topic>` (live, updated on `state.changed`) and call methods with
   `Helper.call(method, params, function (result, error) {})`. Add the topic or reply to
   `assets/demo.json` so `--demo` and the captures show it.
5. Run `scripts/remote.zsh` and compare the shots with the Mac captures until they match.

## Helper client

`HelperClient` starts the helper with `QProcess`, speaks JSON-RPC 2.0 with one JSON object per line,
matches replies by id in any order, applies `state.changed` by rev (a gap resubscribes), cancels a
timed-out request with `$/cancelRequest`, and restarts a crashed helper with backoff (0.5 s doubling
to 30 s). It never logs params or replies: the `switch.helper` category logs method, id, duration
and error kind only.

## Screenshots

`scripts/shots.sh <binary> <out>` runs on the build host inside a private `kwin_wayland --virtual`
(own socket and D-Bus session) and writes `<surface>-<theme>@<scale>x.png` for every page, the
gallery, and the popover (arrow up, expanded, arrow down), Light and Dark, 1x and 2x. A second pass
writes content-only Settings shots to `compare/` and `compare/update/`. A page or popover that failed to
load prints `FAILED <page>: <file>:<line>: <error>`; every other surface is still captured, and the run exits 1.

`scripts/build.sh` builds with qmlcachegen, as shipped. qmlcachegen stops at the first QML syntax error and
has no keep-going flag, so when the build fails, the script builds again with `-DSWITCH_CACHEGEN=OFF`
(`NO_CACHEGEN`) and only the broken file fails at run time. Qt 6.12 reads `Easing.*` as undefined without
qmlcachegen, so that fallback build has no easing curves.

`scripts/compare.sh <qt shots> <mac captures> <out>` writes `<name>-side.png` (Qt left, Mac right)
and `<name>-diff.png`, and prints the share of pixels that differ by more than 3% and the RMSE.

## Second build host (oci2)

`oci2` (arm64, 4 cores, idle) builds and captures in the `switch-qt:tw` container (`scripts/oci/Dockerfile`):
openSUSE Tumbleweed with the same Qt 6.12.0 and KWin 6.8.2 as lin1. Every worker has its own folders and lock,
so nothing queues. From the Mac:

```sh
packages/qt-gui/scripts/remote-oci.zsh <worker> [build|shots|all|clean]   # default all
```

- On oci2: `/mnt/sdb/data/switch/qt/<worker>/` holds `src`, `build` and `shots`. On the Mac:
  `.../switch/qt-gui/shots/<worker>/qt` (PNGs) and `.../shots/<worker>/compare` (Settings against the Mac).
- Times: full build 2 min (3 at once: 5.5 min each), a one-file change 12 s, all captures 1 min.
- Real helper: `/mnt/sdb/data/switch/qt/helper` holds a Linux arm64 `switch-core` (with its Swift libraries in
  `lib/`), mounted read-only at `/opt/helper`. The client test also runs `realHelper` against it; the app takes
  `--helper /opt/helper/switch-core --root <temporary folder>`.
- Differences from lin1: arm64, and Mesa on oci2's render node (`/dev/dri/renderD128`, passed into the container;
  without it `kwin_wayland` quits and a resized popover keeps its old size). The same commit's captures match
  lin1's in size, with at most 0.21% of pixels different (glyph edges).
- Cleanup: `remote-oci.zsh <worker> clean` deletes `/mnt/sdb/data/switch/qt/<worker>` (about 40-90 MB each).
  The image takes 1.9 GB on oci2's system disk. To refresh Tumbleweed, rebuild it with the command at the top of
  the Dockerfile, check `qtpaths6 --qt-version` against lin1, and remove the old image by its ID.

## Windows: open items

Done in code, not yet built on Windows: helper `switch-core.exe` next to the app (`main.cpp`), `USERPROFILE` set
with `--root` (`HelperClient::launch`), Direct3D 11 instead of forced OpenGL (`main.cpp`), white tray mark on a dark
taskbar (`Tray::Tray`), `WIN32_EXECUTABLE` for shipping builds (`CMakeLists.txt`). To decide or test on Windows:

- Build: MSVC Qt 6.12, `windeployqt` (must ship `qsvg`, the Direct3D compiler, `opengl32sw.dll` only if needed); `scripts/*.sh` are Linux only.
- Exe icon: no `.ico` or `.rc` exists; `setWindowIcon(appicon.png)` covers only the taskbar at run time. Make one from the Mac `AppIcon.png`.
- Window chrome (`Main.qml` `flags`, `TrafficLights`, `startSystemResize(Qt.BottomEdge)`): frameless means no DWM shadow, Windows 11 corners or Snap Layouts; shell.md keeps the left buttons. Test Aero Snap, maximize (height only), and the shadow; decide DWM attributes.
- Dark title bar: no native title bar is shown, so `DWMWA_USE_IMMERSIVE_DARK_MODE` matters only if chrome goes native; check the Account sheet (`Qt.Dialog | Frameless`).
- Per-monitor DPI: `QT_FONT_DPI=96` (`main.cpp`) sets only Qt's logical DPI after scaling, so 150% should still scale by 1.5; confirm sizes at 100/150/175% and when the window moves between monitors.
- Fonts: Inter variable through DirectWrite (weights 400-700), `NoSubpixelAntialias` and hinting against the Mac captures.
- Tray popover (`Tray::place`): bottom taskbar is handled; left or right taskbars and an icon in the overflow area (`QSystemTrayIcon::geometry`) are not. Test all four edges.
- Tray tone (`Tray::Tray`): read once at start; a taskbar mode change needs a restart. Linux never sets `darkTray`.
- Helper stop (`HelperClient::stop`): closes stdin, then `kill` (TerminateProcess) after 2 s; check the helper exits 0 and no console window flashes at start.
- Single instance: not built on any platform; Windows wants a named mutex plus a pipe to show the first window (shell.md 1.5).
- Notifications: none in the GUI yet; Windows wants a silent toast with a registered AppUserModelID (shell.md 6.4).
- Global shortcut: `GlobalShortcut` (Linux: the XDG GlobalShortcuts portal) is off on Windows; Windows wants `RegisterHotKey` (shell.md 5); key text says "Super" (`SettingsPage.qml` `comboText`).
- Terminal emulator setting (rpc.md `terminalEmulator`): no UI yet; decide whether Windows shows it (Windows Terminal or console).
- Windows paths in QML: `AccFact.isPath` and `AccDailyCard` test for a leading `/`; `AddAccountSheet` splits on `/`; the demo data locations in `SettingsPage.qml` are XDG paths.
- Copy: "~/.zshrc", "Terminal" and "Super" are Mac or Linux words (shell.md 4, Search.js, SettingsPage.qml).
- Open at Login (`AppState::setLoginEnabled`, HKCU Run): test the quoted path with spaces and `--background`.
