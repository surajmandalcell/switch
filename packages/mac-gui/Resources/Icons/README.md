# App icons

`SwitchMarkPixelTrace.svg` is the approved direct trace of the supplied mark.
It preserves the source silhouette, upper circular counter, and lower open
annulus without reconstructing or hand-fitting their geometry.
`SwitchMarkMenubar.svg` and `ManagerMark.svg` place that same trace at the
appropriate optical size; neither changes its shape.

`AppIconLight.svg` and `AppIconDark.svg` provide explicit Dock treatments. Both
keep a light neutral macOS tile and exact dark-ink Pixel trace. The trace
uses a 520-point foreground box with generous internal clearance. Surface shade
is shallow, and the one-point top-left edge lift peaks at seven percent opacity
in Light and five percent in Dark. The app swaps these treatments with its
selected appearance. `AppIcon.svg` aliases the light treatment used by Spotlight
and the checked-in `AppIcon.icns`.

Run `scripts/build-icons.sh` to regenerate PNGs and the macOS ICNS. It uses
the installed `rsvg-convert` and macOS `iconutil`; normal app builds use the
checked-in outputs and need neither SVG parsing nor an icon dependency at runtime.

`SWITCH-MARK-PROVENANCE.txt` records the supplied reference digest, tracing
settings, and measured fidelity.

The `Provider*` files are unchanged official provider marks used in the Add
Account catalog. `PROVIDER-ICON-PROVENANCE.txt` records their primary sources,
retrieval date, exact digests, and ownership notice.
