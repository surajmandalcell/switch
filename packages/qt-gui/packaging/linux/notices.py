"""Write the Qt notice file: the shipped Qt files with their module and license, the source offer, and the
third-party notices from the Qt sources (qt_attribution.json). usage: notices.py <app folder> <Qt version> <Qt source dir>"""
import json
import pathlib
import sys

app, version, src = pathlib.Path(sys.argv[1]), sys.argv[2], pathlib.Path(sys.argv[3])
short = ".".join(version.split(".")[:2])


def module(rel):
    if "libicu" in rel:
        return "ICU (built into the official Qt binaries)", "Unicode-3.0, see ICU-LICENSE.txt"
    if "Svg" in rel or "svg" in rel:
        name = "qtsvg"
    elif "ayland" in rel:
        name = "qtwayland"
    elif rel.startswith("qml/") or "Qml" in rel or "Quick" in rel:
        name = "qtdeclarative"
    else:
        name = "qtbase"
    return name, "LGPL-3.0-only, see Qt-LGPL-3.0.txt and GPL-3.0.txt"


print(f"""Qt {version} notices for Switch

Switch uses the Qt libraries under the GNU Lesser General Public License v3 (LGPL-3.0-only).
Qt is linked dynamically. You may replace the Qt libraries in lib/, plugins/ and qml/ with your own build of
Qt {version} (the same major and minor version), for example one built from the sources below.

Source code of this Qt version:
  https://download.qt.io/official_releases/qt/{short}/{version}/submodules/
  (qtbase, qtdeclarative, qtsvg and qtwayland -everywhere-src-{version} archives)
  https://code.qt.io/cgit/qt/ (git, tag v{version})
On request we send the same sources on a physical medium for the cost of shipping, for three years from
the release of this package. Ask through https://github.com/surajmandalcell/switch/issues.

Shipped Qt files (module, license):""")
for f in sorted(app.rglob("*")):
    rel = str(f.relative_to(app))
    if f.is_file() and (rel.startswith(("plugins/", "qml/")) and f.suffix == ".so" or "libQt6" in rel or "libicu" in rel):
        name, lic = module(rel)
        print(f"  {rel}  ({name}; {lic})")

print("\nThird-party code inside these Qt modules:\n")
for attr in sorted(src.rglob("qt_attribution.json")):
    data = json.loads(attr.read_text(encoding="utf-8", errors="replace"), strict=False)  # some files hold raw tabs
    for e in data if isinstance(data, list) else [data]:
        if e.get("QtUsage", "").lower().startswith("not used"):
            continue
        print("=" * 100)
        print(f"{e.get('Name', '?')} {e.get('Version', '')}  ({e.get('License', '?')})")
        copyright_text = e.get("Copyright", "")
        print("\n".join(copyright_text) if isinstance(copyright_text, list) else copyright_text)
        files = e.get("LicenseFiles") or [e.get("LicenseFile")]
        for lf in filter(None, files):
            p = attr.parent / lf
            if p.is_file():
                print("\n" + p.read_text(encoding="utf-8", errors="replace"))
