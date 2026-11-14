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
  wrapMode: Text.NoWrap
}
