import QtQuick
import QtQuick.Effects
import "ProviderBrand.js" as B

// ProviderMark (accounts.md 2.8, PRV:43-73): radius 0.22 x size, 1 px separator border, clipped. A brand mark
// sits on its tile color (full icons edge to edge, others padded 0.2 x size); a provider without a brand gets
// its template glyph (padded 0.22 x size) in the label color on ink 8%, else a monogram.
Rectangle {
  id: tile
  property string provider: "codex"
  property string name: provider
  property real size: 16
  readonly property var brand: B.brand(provider)
  readonly property string art: brand ? "assets/providers/brand/" + brand.file + ".png" : B.glyph(provider)
  readonly property bool tinted: art !== "" && (!brand || brand.kind === "tint")
  readonly property real pad: brand ? (brand.kind === "full" ? 0 : size * 0.2) : size * 0.22
  width: size
  height: size
  radius: size * 0.22
  color: brand ? brand.tile : Theme.ink(0.08)

  Item {
    anchors.fill: parent
    // full icons are square art: cut the tile's rounded corners out of them
    layer.enabled: !!tile.brand && tile.brand.kind === "full"
    // threshold 0.5 with spread 1 is a 0..1 alpha ramp; threshold 0 would let alpha 0 through
    layer.effect: MultiEffect { maskEnabled: true; maskSource: round; maskThresholdMin: 0.5; maskSpreadAtMin: 1 }
    Image {
      id: img
      anchors.fill: parent
      anchors.margins: tile.pad
      visible: !tile.tinted
      source: tile.art !== "" && !tile.tinted ? tile.art : ""
      sourceSize: Qt.size(128, 128)
      fillMode: Image.PreserveAspectFit
      smooth: true
      mipmap: true
    }
    // a single-color mark: the art's alpha cut out of the tint color
    Image {
      id: shape
      anchors.fill: parent
      anchors.margins: tile.pad
      visible: false
      layer.enabled: tile.tinted
      source: tile.tinted ? tile.art : ""
      sourceSize: Qt.size(128, 128)
      fillMode: Image.PreserveAspectFit
      smooth: true
      mipmap: true
    }
    Rectangle {
      anchors.fill: shape
      visible: tile.tinted
      color: tile.brand ? tile.brand.mark : Theme.label
      layer.enabled: tile.tinted
      layer.effect: MultiEffect { maskEnabled: true; maskSource: shape; maskThresholdMin: 0.5; maskSpreadAtMin: 1 }
    }
  }
  Item {
    id: round
    anchors.fill: parent
    visible: false
    layer.enabled: true
    Rectangle { anchors.fill: parent; radius: tile.radius }
  }
  Txt {
    visible: tile.art === ""
    anchors.centerIn: parent
    role: "caption"
    wght: 600
    font.pointSize: tile.size * 0.6 * 0.75
    text: (tile.name || "?").charAt(0).toUpperCase()
  }
  Rectangle { anchors.fill: parent; radius: parent.radius; color: "transparent"; border.width: Theme.hair; border.color: Theme.separator }
}
