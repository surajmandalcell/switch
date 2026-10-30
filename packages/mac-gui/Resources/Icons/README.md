# App icons

`AppIconEmergencyStop.png` is the owner's selected red emergency-stop switch
artwork. It also supplies MacPowerToys' Switch image set. The Dock icon uses the
button cut out of it, `../AppIcon.icon/Assets/Button.png`, on a cream tile that
turns warm stone in the Dark icon style. `scripts/build-app-icon.sh` compiles the
Icon Composer source `../AppIcon.icon` into `AppIcon.car` (shipped as
`Assets.car`, named by `CFBundleIconName`), which macOS 26 and later draw at the
full Dock size, and renders `AppIconLight.png` and `AppIconDark.png` on the Apple
grid for the `.icns` and the Dock image the app sets when its appearance setting
differs from the system. `AppIconLight.svg`, `AppIconDark.svg`, and `AppIcon.svg`
remain as historical artwork but no longer generate the app icon.

`SwitchMarkPixelTrace.svg` is the approved direct trace of the supplied mark.
It preserves the source silhouette, upper circular counter, and lower open
annulus without reconstructing or hand-fitting their geometry.
`SwitchMarkMenubar.svg` and `ManagerMark.svg` place that same trace at the
appropriate optical size; neither changes its shape.

Run `scripts/build-icons.sh` to regenerate the app icon PNGs and macOS ICNS
from those sources. The small menu-bar and rail marks still use the
original vector trace. Normal app builds use the checked-in outputs and need
no icon dependency at runtime.

`SWITCH-MARK-PROVENANCE.txt` records the supplied reference digest, tracing
settings, and measured fidelity.

`ProviderBrand/` holds the official logo of every provider that has one, drawn
by `ProviderMark` on the brand's tile. `ProviderBrand/BRAND-SOURCES.md` records
each source, license, and tile look.
