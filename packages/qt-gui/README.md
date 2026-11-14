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
(`lin1`), builds there under the shared lock, captures, and compares (see Screenshots).

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
fonts/                Inter (SIL OFL, see fonts/LICENSE.txt)
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
- No dependency beyond Qt.

Linked Qt modules: Core, Gui, Qml, Quick, Widgets (tray menu), GuiPrivate (harness builds only),
Test (test only). QML modules loaded at run time: QtQuick, QtQuick.Window, QtQuick.Shapes,
QtQuick.Effects (all part of Qt Declarative, LGPL). A shipping build sets `-DSWITCH_HARNESS=OFF
-DSWITCH_TESTS=OFF`.

## Adding a page

1. Read the page spec in `specs/port/` and the Mac capture.
2. Create `qml/pages/<Name>Page.qml`. Its root `Item` has `property alias header: header`, a
   `PageHeader { id: header }` on top and a `ScrollArea` below (see `SettingsPage.qml`).
   Build every control from `qml/components`; add a token to `Theme.qml` only when the spec names it.
3. In `qml/shell/Main.qml`, map the route to the new component in the page `Loader` and drop the
   `spec` field of that page entry (that field makes it a placeholder).
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
writes content-only Settings shots to `compare/` and `compare/update/`.

`scripts/compare.sh <qt shots> <mac captures> <out>` writes `<name>-side.png` (Qt left, Mac right)
and `<name>-diff.png`, and prints the share of pixels that differ by more than 3% and the RMSE.
