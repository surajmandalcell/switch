# App icons

The mark is Google's exact [Material Symbols Rounded `switch_account` filled
24 px glyph](https://github.com/google/material-design-icons/blob/40a7a292a79d9394157e1ea24f83d52d5e17c556/symbols/web/switch_account/materialsymbolsrounded/switch_account_fill1_24px.svg).
Its path data is unchanged; `ManagerMark.svg` only adds `currentColor` styling
so the same monochrome template works in the menu bar and app rail. The source
glyph is Apache-2.0 licensed; the license is included in
`LICENSE-MATERIAL-SYMBOLS.txt` and bundled with the app.

The Dock and Spotlight icon uses a graphite-blue macOS tile, a warm-white
glyph, a restrained surface gradient, and light only along the top-left edge.
The menu-bar template keeps the same licensed glyph at 18 points inside the
native 22-point canvas so it matches the visual weight of standard status icons.

Run `scripts/build-icons.sh` to regenerate PNGs and the macOS ICNS. It uses
the installed `rsvg-convert` and macOS `iconutil`; normal app builds use the
checked-in outputs and need neither SVG parsing nor an icon dependency at runtime.
