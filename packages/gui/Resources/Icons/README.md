# App icons

The mark combines existing [Lucide bot](https://github.com/lucide-icons/lucide/blob/0.577.0/icons/bot.svg)
and [sliders-horizontal](https://github.com/lucide-icons/lucide/blob/0.577.0/icons/sliders-horizontal.svg)
geometry. The robot body is filled, its eyes become cutouts, and the top slider
row replaces the antenna. No new glyph paths are drawn. Lucide 0.577.0's license
is included in `LICENSE-LUCIDE.txt` and bundled with the app.

The Dock icon uses Recap Pro Producer's charcoal `#1b1c20`, warm-white
`#ecebe7`, and rounded-tile proportions. The tray and rail use the same mark as
a monochrome template so macOS can tint it for light/dark menu bars.

Run `scripts/build-icons.sh` to regenerate PNGs and the macOS ICNS. It uses
the installed `rsvg-convert` and macOS `iconutil`; normal app builds use the
checked-in outputs and need neither SVG parsing nor an icon dependency at runtime.
