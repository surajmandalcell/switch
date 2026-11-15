import QtQuick

// One text role of the design system (2.1): Inter tuned to the SF Pro sizes, weights and tracking.
Text {
  property string role: "body"
  property bool tabular: false
  property int wght: Theme.roles[role].w
  readonly property real px: Theme.roles[role].px * Theme.fontScale

  color: Theme.label
  font.family: Theme.fontFamily
  font.pointSize: px * 0.75
  font.weight: wght >= 650 ? Font.Bold : (wght >= 550 ? Font.DemiBold : Font.Normal)
  font.variableAxes: ({ "wght": wght })
  font.features: tabular ? ({ "tnum": 1 }) : ({})
  font.letterSpacing: Theme.roles[role].ls * px
  font.hintingPreference: Font.PreferNoHinting
  lineHeight: Theme.roles[role].lh
  lineHeightMode: Text.FixedHeight
  verticalAlignment: Text.AlignVCenter
  horizontalAlignment: Text.AlignLeft   // explicit, so text that starts with Arabic or Hebrew stays leading like the Mac
  wrapMode: Text.NoWrap

  // A fallback font with a tall ascent (Noto Sans Arabic or Hebrew) pushes the whole fixed-height line down onto
  // the next row. Only such text gets a paint-only shift back to the Inter baseline; Latin text never changes.
  readonly property bool rtlText: /[֐-ࣿיִ-﷿ﹰ-﻿]/.test(text)
  property Translate inkShift: null
  function armInkShift() {
    if (!rtlText || inkShift) return
    inkShift = Qt.createQmlObject("import QtQuick; Translate { property FontMetrics fm: FontMetrics {} }", this)
    inkShift.fm.font = Qt.binding(function () { return font })
    inkShift.y = Qt.binding(function () {
      return rtlText && lineHeightMode === Text.FixedHeight ? -Math.round(baselineOffset - ((lineHeight - inkShift.fm.height) / 2 + inkShift.fm.ascent)) : 0 })
    transform = [inkShift]
  }
  onRtlTextChanged: armInkShift()
  Component.onCompleted: armInkShift()
}
