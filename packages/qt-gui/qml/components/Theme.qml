pragma Singleton
import QtQuick

// Design tokens from specs/port/design-system.md sections 1 to 3. Where the Mac captures
// (update-check/settings-*.png) measure a different value, the capture wins and the line says so.
QtObject {
  id: t

  // "system" | "light" | "dark"
  property string mode: "system"
  readonly property bool systemDark: Qt.styleHints.colorScheme === Qt.Dark
  readonly property bool dark: mode === "dark" || (mode === "system" && systemDark)
  // Screenshot runs turn motion off (design-system.md 3.4, last line); Reduce Motion keeps fades.
  property bool motion: true
  property bool reduceMotion: false
  // Settings > Usage percentage (settings.md 6.4): every meter, percent and tooltip shows left or used.
  property bool showUsed: false
  function shownPercent(used) { return Math.round(showUsed ? used : 100 - used) }

  property real dpr: 1
  readonly property real hair: 1 / dpr
  property string fontFamily: "Inter Variable"
  // Where the app icon lives, from the helper's `app` topic (core PlatformText): "notification area" on Windows,
  // "system tray" on Linux.
  property string trayName: ""
  readonly property string trayTitle: trayName.charAt(0).toUpperCase() + trayName.slice(1)
  // code, paths and IDs (design-system 2.3: SF Mono stand-in), bundled in fonts/ so it looks the same everywhere
  property string monoFamily: "JetBrains Mono"
  // Inter against SF Pro: the same cap height needs about 0.97 of the size.
  property real fontScale: 0.97

  property real windowRadius: 10
  // Shared window pieces, set by Main.qml.
  property var menu: null
  property var tooltip: null
  property var alert: null
  property Item pageHost: null

  readonly property var roles: ({
    "title":     { px: 17, w: 600, lh: 22, ls: -0.024 },
    "section":   { px: 13, w: 700, lh: 16, ls: -0.006 },
    "body":      { px: 13, w: 400, lh: 16, ls: -0.006 },
    "secondary": { px: 11, w: 400, lh: 14, ls:  0.006 },
    "caption":   { px: 10, w: 400, lh: 13, ls:  0.012 }
  })

  function rgba(c, a) { var q = Qt.color(c); return Qt.rgba(q.r, q.g, q.b, a) }
  function k(a) { return Qt.rgba(0, 0, 0, a) }
  function w(a) { return Qt.rgba(1, 1, 1, a) }
  function ink(a) { return dark ? w(a * 0.847) : k(a * 0.847) }   // Color.primary.opacity(a)

  // 1.1 system colors
  readonly property color accent: "#007AFF"
  readonly property color label:      dark ? w(0.847) : k(0.847)
  readonly property color secondary:  dark ? w(0.549) : k(0.498)
  readonly property color tertiary:   dark ? w(0.247) : k(0.259)
  readonly property color quaternary: dark ? w(0.098) : k(0.098)
  // Dark separator: overview-dark.png card dividers measure #3D3D3D on the #282828 card, white 9.8%
  // (#424242 there is the selected row fill, rowHighlight).
  readonly property color separator:  dark ? w(0.098) : k(0.098)
  readonly property color green:  dark ? "#30D158" : "#34C759"
  readonly property color yellow: dark ? "#FFD600" : "#FFCC00"
  readonly property color red:    dark ? "#FF4245" : "#FF383C"
  readonly property color amber:  dark ? "#FF9230" : "#FF8D28"
  readonly property color link:   dark ? "#419CFF" : "#0068DA"

  // 1.2 app tokens
  // Dark page = windowBackgroundColor: #323232 in the real window captures (overview-dark.png, accounts-dark.png).
  // The #1E1E1E in compare/settings-dark-mac.png is an offscreen render without window chrome.
  readonly property color page:       dark ? "#323232" : "#F6F6F6"
  readonly property color card:       dark ? "#282828" : "#FFFFFF"
  readonly property color cardBorder: dark ? w(0.05) : k(0.10)
  readonly property color hairline:   separator
  readonly property color tableSeparator: dark ? w(0.04) : k(0.06)
  readonly property color guideLine:  dark ? w(0.13) : k(0.13)
  readonly property color rowHover:   dark ? w(0.07) : k(0.06)
  readonly property color tileFill:   dark ? w(0.04) : k(0.025)
  readonly property color controlFill: dark ? w(0.12) : "#FFFFFF"
  readonly property color controlPressed: dark ? w(0.20) : "#EDEDED"
  readonly property color controlBorder: dark ? "transparent" : k(0.14)
  readonly property color primaryBorder: dark ? "transparent" : k(0.12)
  readonly property color controlShadow: dark ? "transparent" : k(0.06)
  readonly property color segmentTrack: dark ? w(0.08) : k(0.06)
  readonly property color segmentSelected: dark ? w(0.20) : "#FFFFFF"
  readonly property color switchOff: dark ? w(0.18) : k(0.12)
  readonly property color focusTint: dark ? w(0.08) : rgba(accent, 0.16)
  readonly property color rowHighlight: dark ? w(0.12) : rgba(accent, 0.12)
  readonly property color sidebarSelection: dark ? w(0.12) : rgba(accent, 0.18)
  readonly property color checkboxSelection: dark ? w(0.12) : rgba(accent, 0.22)
  readonly property color checkedControlFill: dark ? w(0.20) : accent
  // Light: the Mac sidebar captures measure the accent as rendered there (#3478F6), not #007AFF.
  readonly property color passiveIcon: dark ? label : "#3478F6"
  readonly property color badgeFill: dark ? w(0.10) : k(0.06)
  readonly property color usageTrack: dark ? w(0.049) : k(0.049)
  readonly property color skeleton: ink(0.07)
  readonly property color neutralBar: dark ? "#98989D" : "#8E8E93"

  // 3.2 materials. The sidebar is flat in the Mac captures (#F0F0F0 / #282828): no wash.
  // The Mac sidebar is a material over the desktop; these are its measured tints in docs/screenshots
  // (overview-light.png #E6E4E4, accounts-dark.png #282524), a warm gray slightly darker than a neutral one.
  readonly property color sidebar: dark ? "#282524" : "#E6E4E4"
  readonly property color windowBorder: dark ? w(0.14) : k(0.20)
  readonly property color solidSurface: dark ? "#262628" : "#FFFFFF"   // search dropdown, menus, tooltips
  // Popover body (popover.md 2.1): the opaque Reduce Transparency colors are the portable baseline.
  // Light measured from the Mac popover render (menubar-light.png): #F2F2F2.
  readonly property color popoverFill: dark ? "#262628" : "#F2F2F2"
  // menubar-*.png edge pixel: a white rim in Light (#FFFFFF over the fill), almost none in Dark (#282829).
  readonly property color popoverBorder: dark ? w(0.02) : "#FFFFFF"
  readonly property color popoverHover: ink(0.04)
  readonly property color popoverFocus: ink(0.06)
  readonly property color popButtonFill: dark ? w(0.08) : k(0.08)    // measured on menubar-*.png (#DFDFDF / #373739)
  readonly property color popButtonHover: ink(0.06)
  readonly property color popButtonPress: ink(0.10)

  // 1.4 brand bar colors: UsageBarColor.table (AIManagerDesign.swift); one value = both appearances.
  readonly property var brands: ({
    "codex": ["#0AA17D", "#10A37F"], "openai": ["#0AA17D", "#10A37F"],
    "claude-code": ["#D57354", "#D97757"], "droid": ["#EE6018", "#EE6018"], "factory": ["#EE6018", "#EE6018"],
    "gemini-cli": ["#4285F4", "#4285F4"], "cursor": ["#F54E00", "#F54E00"], "copilot": ["#8534F3", "#8F43FF"],
    "abacus": ["#0092B0", "#39C3E7"], "aerostack": ["#C97C00", "#FCAB4A"], "aiand": ["#C70007", "#DC2A22"],
    "aixy": ["#123650", "#527794"], "alibaba": ["#EE6200", "#FF6A00"], "alibabatokenplan": ["#EE6200", "#FF6A00"],
    "antigravity-cli": ["#4285F4"], "atlascloud": ["#7036F0", "#7D4EFF"], "augment": ["#1AA049"],
    "azureopenai": ["#0961AE", "#2675C3"], "bedrock": ["#0066FF", "#0568FF"], "bifrost": ["#00A082", "#45D2AF"],
    "chutes": ["#2AA16A", "#63D297"], "commandcode": ["#2E1B9C", "#6063E4"], "cosmic": ["#0098CE", "#29ABE2"],
    "deepgram": ["#00A266", "#00F099"], "deepinfra": ["#2A3275", "#606EB7"], "deepseek": ["#4D6BFE"],
    "doubao": ["#3C8CFF"], "elevenlabs": ["#2B7FFF"], "exa": ["#2142ED", "#3764FF"], "fireworks": ["#6726FE", "#7453FF"],
    "gitkraken": ["#149185"], "groq": ["#F55036"], "helmcode": ["#4632D7", "#605BFE"], "huggingface": ["#AA8B00", "#FFD21E"],
    "hyper": ["#D65DD7", "#FF84FF"], "ibmbob": ["#001D6D", "#4670C7"], "jetbrains": ["#F001A0"], "kilo": ["#A48D00", "#FFDD00"],
    "kimi-api": ["#007CFF"], "kimi": ["#007CFF"], "kiro": ["#9046FF"], "langdock": ["#4469FC"], "linkup": ["#EA643E", "#EB653F"],
    "litellm": ["#061BBF", "#2F65FF"], "lithosai": ["#2F5D8A", "#4776A5"], "llmman": ["#668CE0", "#7AA2F7"],
    "longcat": ["#00A435", "#29E154"], "minimax": ["#EA2F6F"], "mistral": ["#EA6600", "#FF7000"], "moonshot": ["#007CFF"],
    "muse": ["#0866FF", "#0A67FF"], "neuralwatt": ["#D55934"], "notion": ["#2383E2"], "perplexity": ["#01838C"],
    "pi": ["#D17467", "#F09082"], "qoder": ["#8B5CF6"], "qwencloud": ["#615CED", "#635FF0"], "raycast": ["#F4585A", "#FF6363"],
    "replicate": ["#E63336"], "sailresearch": ["#2C4681", "#5472B0"], "sakana": ["#E10600", "#E51107"],
    "sofya": ["#8F9400", "#A9B01F"], "synthetic": ["#6366F1"], "t3chat": ["#C31889", "#CF2A93"], "tavily": ["#699782", "#81B09A"],
    "tinyapi": ["#CF7703"], "typesafe": ["#DF4FB5"], "venice": ["#163048", "#597691"], "vertexai": ["#4285F4"],
    "warp": ["#0094E8", "#01A4FF"], "workbuddy": ["#00A081", "#0EC9A2"], "xkiro": ["#00A449", "#22C65E"], "zai": ["#0B7FFF"],
    "zed": ["#084CCF", "#286AEF"], "zoommate": ["#0B5CFF", "#1D66FF"]
  })
  function brand(id) { var b = brands[id]; return b ? b[dark ? b.length - 1 : 0] : neutralBar }
  function usageColor(id, used) { return used >= 90 ? red : brand(id) }

  // 3.4 motion
  readonly property var easeOut: [0, 0, 0.58, 1, 1, 1]
  readonly property int dState: motion ? 100 : 0
  readonly property int dHover: motion ? 120 : 0
  readonly property int dFill: motion ? 350 : 0
  readonly property int dAppear: motion ? 250 : 0
  readonly property int dFilter: motion ? 180 : 0

  // 4.24 popover outline. AppKit draws it, so the repo has no values. The corner is measured from the
  // Mac popover render (docs/screenshots/menubar-light.png, bottom-left corner, first body pixel per row):
  // a circle of radius 20 fits within 0.5 px on every row (16 misses by 3 px). The render has no arrow
  // and no window shadow, so the arrow size and the shadow stay estimates.
  readonly property real popoverRadius: 20
  readonly property real arrowWidth: 30
  readonly property real arrowHeight: 12
}
