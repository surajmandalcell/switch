import QtQuick

// ProviderMark (4.12): radius 0.22 x size, 1 px separator border, brand tile color. Stand-in marks until
// the brand artwork (Resources/Icons/ProviderBrand) is converted; unknown providers get a monogram.
Rectangle {
  id: tile
  property string provider: "codex"
  property string name: provider
  property real size: 16
  readonly property var look: ({
    "codex":       { bg: "#FFFFFF", fg: "#000000", mark: "markCodex" },
    "claude-code": { bg: "#D96F4C", fg: "#FFFFFF", mark: "markClaude" },
    "droid":       { bg: "#020202", fg: "#FAFAFA", mark: "markDroid" },
    "factory":     { bg: "#020202", fg: "#FAFAFA", mark: "markDroid" }
  })[provider]
  width: size
  height: size
  radius: size * 0.22
  color: look ? look.bg : Theme.ink(0.08)
  Icon { visible: !!tile.look; anchors.centerIn: parent; size: tile.size * 0.74; name: tile.look ? tile.look.mark : ""; color: tile.look ? tile.look.fg : Theme.label }
  Txt {
    visible: !tile.look
    anchors.centerIn: parent
    role: "caption"
    wght: 600
    font.pointSize: tile.size * 0.6 * 0.75
    text: (tile.name || "?").charAt(0).toUpperCase()
  }
  Rectangle { anchors.fill: parent; radius: parent.radius; color: "transparent"; border.width: Theme.hair; border.color: Theme.separator }
}
