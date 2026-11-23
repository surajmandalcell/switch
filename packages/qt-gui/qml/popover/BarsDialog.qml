import QtQuick
import QtQuick.Window

// Choose Bars (Mac MenuBarBarsDialog): which usage bars one service shows in the popover's collapsed row
// ("At a glance") and expanded row. tray.bars.* applies the defaults and the locks (first two at a glance,
// all expanded, glance bars always expanded, one glance bar minimum); the tray topic republishes with picks.
Window {
  id: dlg
  property string providerID: ""
  property string providerName: ""
  property var rows: []            // tray.bars reply bars[]: {id, label, glance, expanded, isDefaultGlance, isDefaultExpanded}
  property bool isCustom: false
  readonly property bool isDefault: !isCustom

  width: 440
  // at most 90% of the screen: the title and the buttons stay, the middle scrolls
  height: Math.min(headH + body.contentH + footH, Math.round(Screen.desktopAvailableHeight * 0.9))
  flags: Qt.Dialog | Qt.FramelessWindowHint
  color: "transparent"
  title: "Bars for " + providerName
  visible: false

  readonly property int glanceCount: rows.filter(function (r) { return r.glance }).length

  function take(id) { return function (r, e) { if (!e && r && r.bars && dlg.providerID === id) { dlg.rows = r.bars || []; dlg.isCustom = !!r.isCustom } } }
  function load(id, name) {
    providerID = id; providerName = name; rows = []; isCustom = false
    Helper.call("tray.bars.get", { providerID: id }, take(id))
    x = Screen.virtualX + (Screen.desktopAvailableWidth - width) / 2
    y = Screen.virtualY + (Screen.desktopAvailableHeight - height) / 3
    show(); requestActivate()
  }
  function pick(map, id, v) {
    var next = rows.map(function (r) { var c = Object.assign({}, r); if (r.id === id) c[map] = v; if (c.glance) c.expanded = true; return c })
    rows = next; isCustom = true
    Helper.call("tray.bars.set", { providerID: providerID,
                                   glance: next.filter(function (r) { return r.glance }).map(function (r) { return r.id }),
                                   expanded: next.filter(function (r) { return r.expanded }).map(function (r) { return r.id }) }, take(providerID))
  }
  function reset() { Helper.call("tray.bars.reset", { providerID: providerID }, take(providerID)) }

  // Preview: the default account's collapsed lines from the tray topic, which already has the picks applied.
  readonly property var preview: {
    var t = Helper.topics.tray, gs = t && t.groups ? t.groups : []
    for (var i = 0; i < gs.length; ++i) if (gs[i].providerID === providerID) {
      var rs = gs[i].rows.filter(function (r) { return (r.lines || []).length > 0 })
      for (var k = 0; k < rs.length; ++k) if (rs[k].isDefault) return rs[k].lines
      return rs.length ? rs[0].lines : []
    }
    return []
  }

  readonly property real headH: 20 + 12 + 40 + 16
  readonly property real footH: 28 + 32 + Theme.hair

  // Menus and tooltips of the main window cannot draw over this window: borrow them while open.
  property var saved: null
  onVisibleChanged: {
    if (visible) { saved = { t: Theme.tooltip }; Theme.tooltip = tip }
    else if (saved) { Theme.tooltip = saved.t; saved = null }
  }

  Rectangle { anchors.fill: parent; radius: 10; color: Theme.page; border.width: Theme.hair; border.color: Theme.windowBorder }
  Item {
    id: root
    anchors.fill: parent
    focus: true
    Keys.onEscapePressed: dlg.close()
    Keys.onReturnPressed: dlg.close()
    MouseArea { anchors.fill: parent; Accessible.ignored: true; onPressed: dlg.startSystemMove() }

    Column {
      x: 20; y: 32
      width: parent.width - 40
      spacing: 2
      Txt { role: "section"; text: dlg.title }
      Txt { role: "secondary"; color: Theme.secondary; text: "Pick the bars the menu bar shows for this service." }
    }

    ScrollArea {
      id: body
      readonly property real contentH: inner.height + 16
      y: dlg.headH
      width: parent.width
      height: parent.height - dlg.headH - dlg.footH
      gutter: 20
      topPad: 0
      bottomPad: 16
      Column {
        id: inner
        width: parent.width
        spacing: 16

        // the collapsed row, as the popover draws it
        Rectangle {
          visible: dlg.preview.length > 0
          width: parent.width
          height: visible ? pv.height + 24 : 0
          radius: 8
          color: Theme.card
          border.width: Theme.hair
          border.color: Theme.cardBorder
          Accessible.role: Accessible.Grouping
          Accessible.name: "Preview"
          Column {
            id: pv
            x: 12; y: 12
            width: parent.width - 24
            spacing: 4
            Txt { role: "caption"; color: Theme.secondary; text: "At a glance" }
            Repeater {
              model: dlg.preview
              delegate: Item {
                width: pv.width
                height: 18
                Txt { width: 72; anchors.verticalCenter: parent.verticalCenter; role: modelData.isHeading ? "caption" : "secondary"
                      color: Theme.secondary; text: modelData.label || ""; elide: Text.ElideRight }
                Txt { visible: !modelData.isHeading && !!modelData.balance; x: 78; anchors.verticalCenter: parent.verticalCenter
                      role: "secondary"; text: modelData.balance || "" }
                UsageBar { visible: !modelData.isHeading && !modelData.balance; x: 78; width: parent.width - 78 - 6 - 40
                           anchors.verticalCenter: parent.verticalCenter; used: modelData.used === undefined || modelData.used === null ? -1 : modelData.used
                           provider: dlg.providerID }
                Txt { visible: !modelData.isHeading && !modelData.balance; anchors.right: parent.right; width: 40
                      anchors.verticalCenter: parent.verticalCenter; role: "secondary"; tabular: true; color: Theme.secondary
                      horizontalAlignment: Text.AlignRight
                      text: modelData.percentText || (modelData.used === undefined || modelData.used === null ? "—" : Theme.shownPercent(modelData.used) + "%") }
              }
            }
          }
        }

        // the eye table
        Rectangle {
          visible: dlg.rows.length > 0
          width: parent.width
          height: visible ? tbl.height : 0
          radius: 8
          color: Theme.card
          clip: true
          Column {
            id: tbl
            width: parent.width
            Item {
              width: parent.width
              height: 26
              Txt { x: 12; anchors.verticalCenter: parent.verticalCenter; role: "caption"; color: Theme.secondary; text: "Bar" }
              Txt { x: parent.width - 168; width: 84; anchors.verticalCenter: parent.verticalCenter; horizontalAlignment: Text.AlignHCenter
                    role: "caption"; color: Theme.secondary; text: "At a glance" }
              Txt { x: parent.width - 84; width: 84; anchors.verticalCenter: parent.verticalCenter; horizontalAlignment: Text.AlignHCenter
                    role: "caption"; color: Theme.secondary; text: "Expanded" }
            }
            Repeater {
              model: dlg.rows
              delegate: Item {
                id: br
                width: tbl.width
                height: 32 + Theme.hair
                readonly property bool lastGlance: modelData.glance && dlg.glanceCount === 1
                Rectangle { width: parent.width; height: Theme.hair; color: Theme.separator }
                Rectangle { y: Theme.hair; width: parent.width; height: 32; color: index % 2 === 1 ? Theme.rowHover : "transparent" }
                Txt { x: 12; y: Theme.hair; height: 32; width: parent.width - 12 - 168 - 8; verticalAlignment: Text.AlignVCenter
                      text: modelData.label; elide: Text.ElideRight
                      ToolTipArea { text: parent.truncated ? modelData.label : "" } }
                Eye { x: parent.width - 168; shown: modelData.glance; view: "at a glance"; title: modelData.label
                      why: br.lastGlance ? "One bar always stays at a glance" : ""
                      onToggle: dlg.pick("glance", modelData.id, !modelData.glance) }
                Eye { x: parent.width - 84; shown: modelData.expanded; view: "expanded"; title: modelData.label
                      why: modelData.glance ? "Bars at a glance also show when expanded" : ""
                      onToggle: dlg.pick("expanded", modelData.id, !modelData.expanded) }
              }
            }
          }
          // the outline on all four sides, drawn over the rows
          Rectangle { anchors.fill: parent; radius: 8; color: "transparent"; border.width: Theme.hair; border.color: Theme.cardBorder }
        }
        Txt { visible: dlg.rows.length === 0; role: "secondary"; color: Theme.secondary; text: "No usage yet. Bars show here once usage arrives." }
      }
    }

    // footer: hairline, Reset to Default left, Done right
    Rectangle { y: parent.height - dlg.footH; width: parent.width; height: Theme.hair; color: Theme.separator }
    PushButton { objectName: "bars-reset"; x: 16; y: parent.height - 16 - 28; text: "Reset to Default"; enabled: !dlg.isDefault; onClicked: dlg.reset() }
    PushButton { objectName: "bars-done"; x: parent.width - 16 - width; y: parent.height - 16 - 28; prominent: true; text: "Done"; onClicked: dlg.close() }

    Item { id: overlay; anchors.fill: parent }
    Tooltip { id: tip; parent: overlay }
  }

  // One eye cell, 84 wide and centered; a disabled eye is at half opacity and its tooltip says why.
  component Eye: Item {
    property bool shown
    property string view
    property string title
    property string why: ""
    signal toggle()
    objectName: "eye-" + view + "-" + title
    y: Theme.hair
    width: 84
    height: 32
    IconButton {
      anchors.centerIn: parent
      icon: parent.shown ? "eye" : "eyeSlash"
      tone: parent.shown ? "active" : "normal"
      glyph: 16
      enabled: parent.why === ""
      opacity: enabled ? 1 : 0.5
      tip: parent.why !== "" ? parent.why : (parent.shown ? "Hide " : "Show ") + parent.title + " " + parent.view
      Accessible.name: parent.title + " " + parent.view
      Accessible.description: parent.shown ? "Shown" : "Hidden"
      onClicked: parent.toggle()
    }
    // a disabled IconButton takes no hover, so the reason shows from here
    ToolTipArea { text: parent.why }
  }
}
