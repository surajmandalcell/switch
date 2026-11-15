import QtQuick

// Selectable message text (history.md 2.3, 4.2): inline Markdown as rich text, typed line breaks kept, a word
// with no break point breaks anywhere, links open in the browser. Body 13 with 4 pt extra line spacing (20 per
// line); code is Secondary 11 mono with 3 pt (17 per line).
TextEdit {
  id: te
  property string html: ""
  property bool mono: false
  property bool bold: false
  readonly property real px: (mono ? 11 : 13) * Theme.fontScale
  readonly property int lineH: mono ? 17 : 20

  readOnly: true
  selectByMouse: true
  persistentSelection: false
  textFormat: TextEdit.RichText
  wrapMode: TextEdit.WrapAtWordBoundaryOrAnywhere
  color: Theme.label
  selectionColor: Theme.dark ? Theme.w(0.25) : Theme.rgba(Theme.accent, 0.3)
  selectedTextColor: Theme.label
  font.family: mono ? Theme.monoFamily : Theme.fontFamily
  font.pointSize: px * 0.75
  font.weight: bold ? Font.Bold : Font.Normal
  font.letterSpacing: mono ? 0 : -0.006 * px
  font.hintingPreference: Font.PreferNoHinting
  // Paragraph direction from the first strong letter (Unicode bidi rule P2): Hebrew or Arabic make it right to
  // left. Qt rich text keeps a left-to-right paragraph otherwise, so an Arabic sentence ends on the wrong side.
  readonly property bool rtl: {
    var m = /[A-Za-zÀ-ɏͰ-ϿЀ-ӿ]|[֐-ࣿיִ-﷿ﹰ-﻿]/.exec(html.replace(/<[^>]*>/g, ""))
    return !!m && m[0] >= "֐"
  }
  text: "<html><head><style>a { color: " + Theme.link + "; text-decoration: none } code { font-family: '" + Theme.monoFamily + "' }</style></head><body>"
        + "<div" + (rtl ? " dir=\"rtl\"" : "") + " style=\"white-space:pre-wrap; line-height:" + lineH + "px\">" + html + "</div></body></html>"
  onLinkActivated: function (l) { Qt.openUrlExternally(l) }
  HoverHandler { cursorShape: te.hoveredLink !== "" ? Qt.PointingHandCursor : Qt.IBeamCursor }
}
