# App icons

`SwitchMarkBalanced.svg` is a deterministic, symmetry-corrected trace of the
supplied mark. Its four outer lobes have exact rotational symmetry, while the
upper circular counter and lower open annulus preserve the reference layout.
`SwitchMarkMenubar.svg` is an optical variant with wider counters for the
22-point menu-bar template and its 44-pixel representation.

`AppIconLight.svg` and `AppIconDark.svg` provide explicit Dock treatments. Both
keep the graphite macOS tile, warm-white mark, restrained surface shading, and
restrained top-left edge lift. The app swaps these treatments with its selected
appearance. `AppIcon.svg` aliases the light treatment used by Spotlight and the
checked-in `AppIcon.icns`.

Run `scripts/build-icons.sh` to regenerate PNGs and the macOS ICNS. It uses
the installed `rsvg-convert` and macOS `iconutil`; normal app builds use the
checked-in outputs and need neither SVG parsing nor an icon dependency at runtime.

`SWITCH-MARK-PROVENANCE.txt` records the supplied reference digest and final
vector geometry.
