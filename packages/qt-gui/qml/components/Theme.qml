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
  // Inter against SF Pro: the same cap height needs about 0.97 of the size.
  property real fontScale: 0.97

  property real windowRadius: 10
  // Shared window pieces, set by Main.qml.
  property var menu: null
  property var tooltip: null
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
  // Dark separator: the Mac capture measures white 12% (#424242 on the #282828 card), not 9.8%.
  readonly property color separator:  dark ? w(0.12) : k(0.098)
  readonly property color green:  dark ? "#30D158" : "#34C759"
  readonly property color yellow: dark ? "#FFD600" : "#FFCC00"
  readonly property color red:    dark ? "#FF4245" : "#FF383C"
  readonly property color amber:  dark ? "#FF9230" : "#FF8D28"
  readonly property color link:   dark ? "#419CFF" : "#0068DA"

  // 1.2 app tokens
  readonly property color page:       dark ? "#1E1E1E" : "#F6F6F6"
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
  readonly property color passiveIcon: dark ? label : accent
  readonly property color badgeFill: dark ? w(0.10) : k(0.06)
  readonly property color usageTrack: dark ? w(0.049) : k(0.049)
  readonly property color skeleton: ink(0.07)
  readonly property color neutralBar: dark ? "#98989D" : "#8E8E93"

  // 3.2 materials. The sidebar is flat in the Mac captures (#F0F0F0 / #282828): no wash.
  readonly property color sidebar: dark ? "#282828" : "#F0F0F0"
  readonly property color windowBorder: dark ? w(0.14) : k(0.20)
  readonly property color solidSurface: dark ? "#262628" : "#FFFFFF"   // search dropdown, menus, tooltips
  // Popover body (popover.md 2.1): the opaque Reduce Transparency colors are the portable baseline.
  // Light measured from the Mac popover render (menubar-light.png): #F2F2F2.
  readonly property color popoverFill: dark ? "#262628" : "#F2F2F2"
  readonly property color popoverBorder: dark ? w(0.16) : k(0.12)
  readonly property color popoverHover: ink(0.04)
  readonly property color popoverFocus: ink(0.06)
  readonly property color popButtonFill: dark ? w(0.08) : k(0.08)    // measured on menubar-*.png (#DFDFDF / #373739)
  readonly property color popButtonHover: ink(0.06)
  readonly property color popButtonPress: ink(0.10)

  // 1.4 brand bar colors (the rest of the 75-row table lands with the Accounts page)
  readonly property var brands: ({
    "codex": ["#0AA17D", "#10A37F"], "openai": ["#0AA17D", "#10A37F"],
    "claude-code": ["#D57354", "#D97757"], "droid": ["#EE6018", "#EE6018"], "factory": ["#EE6018", "#EE6018"],
    "gemini-cli": ["#4285F4", "#4285F4"], "cursor": ["#F54E00", "#F54E00"], "copilot": ["#8534F3", "#8F43FF"]
  })
  function brand(id) { var b = brands[id]; return b ? b[dark ? 1 : 0] : neutralBar }
  function usageColor(id, used) { return used >= 90 ? red : brand(id) }

  // 3.4 motion
  readonly property var easeOut: [0, 0, 0.58, 1, 1, 1]
  readonly property int dState: motion ? 100 : 0
  readonly property int dHover: motion ? 120 : 0
  readonly property int dFill: motion ? 350 : 0
  readonly property int dAppear: motion ? 250 : 0
  readonly property int dFilter: motion ? 180 : 0

  // 4.24 popover outline. AppKit draws it, so the repo has no values. The corner is measured from the
  // Mac popover render (docs/screenshots/menubar-light.png): it fits a circle of radius 16 within 1 px
  // on every row. The arrow size is not measurable from any capture we have.
  readonly property real popoverRadius: 16
  readonly property real arrowWidth: 30
  readonly property real arrowHeight: 12
}
