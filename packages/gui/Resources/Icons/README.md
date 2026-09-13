# App icons

Switch uses icon #17 from the supplied asset pack. `SwitchMarkBalanced.svg` is
the general app and rail mark. `SwitchMarkMenubar.svg` is the tiny-size variant
used for the 22-point menu-bar template and its 44-pixel representation.

`AppIconLight.svg` and `AppIconDark.svg` provide explicit Dock treatments. Both
keep the graphite macOS tile, warm-white mark, restrained surface shading, and
restrained top-left edge lift. The app swaps these treatments with its selected
appearance. `AppIcon.svg` aliases the light treatment used by Spotlight and the
checked-in `AppIcon.icns`.

Run `scripts/build-icons.sh` to regenerate PNGs and the macOS ICNS. It uses
the installed `rsvg-convert` and macOS `iconutil`; normal app builds use the
checked-in outputs and need neither SVG parsing nor an icon dependency at runtime.

`SWITCH-ICON17-PROVENANCE.txt` records the user-supplied archive and member
digests used to create these assets.
