import QtQuick
import QtQuick.Effects

// The History filter popover (Mac HistoryFilterPanel): 260 wide, 6 padding, on the page color. All providers,
// a hairline, Codex with its apps indented, Claude Code (no apps under it), a hairline, Reset. Rows are 28 high
// with a radius 6 hover fill, a 14 wide check and the count at the right. Rows stay open after a click.
Item {
  id: fp
  property var page
  property Item anchorItem: null
  visible: false
  anchors.fill: parent
  z: 90

  readonly property var present: { var c = page.appCounts; return page.allSources.filter(function (s) { return c[s] !== undefined }) }
  function sum(list) { var n = 0; for (var k = 0; k < list.length; ++k) n += page.appCounts[list[k]] || 0; return n }
  readonly property var codexApps: present.filter(function (s) { return s !== "claude" })
  // structure only: the checks bind to page.appFilter in each row, so a click keeps the rows (and the hover)
  readonly property var rows: {
    var r = [{ a: "all", t: "All providers", n: sum(present) }, { a: "-" }]
    if (codexApps.length) {
      r.push({ a: "codex", t: "Codex", p: "codex", n: sum(codexApps) })
      for (var k = 0; k < codexApps.length; ++k) {
        var s = codexApps[k]
        r.push({ a: "src:" + s, t: s === "codex" ? "Other Codex" : page.appLabels[s], indent: true, n: page.appCounts[s] || 0 })
      }
    }
    if (present.indexOf("claude") >= 0) r.push({ a: "claude", t: "Claude Code", p: "claude-code", n: page.appCounts.claude || 0 })
    r.push({ a: "-" }, { a: "reset", t: "Reset", n: -1 })
    return r
  }
  function group(a) { return a === "codex" ? codexApps : a === "claude" ? ["claude"] : a.indexOf("src:") === 0 ? [a.substring(4)] : [] }
  function checked(a, sel) {
    if (a === "all") return sel.length === 0
    if (a === "reset") return false
    var g = group(a)
    for (var k = 0; k < g.length; ++k) if (sel.length && sel.indexOf(g[k]) < 0) return false
    return true
  }
  function act(a) {
    if (a === "all" || a === "reset") page.setAppFilter([])
    else page.toggleApps(group(a))
  }

  function open(anchor) {
    anchorItem = anchor
    var p = anchor.mapToItem(fp, 0, 0)
    panel.x = Math.max(8, Math.min(fp.width - panel.width - 8, p.x + anchor.width / 2 - panel.width / 2))
    panel.y = p.y + anchor.height + 8
    visible = true
    panel.forceActiveFocus()
  }
  function close() { visible = false; if (anchorItem) anchorItem.forceActiveFocus() }
  function rowItem(a) { for (var k = 0; k < rows.length; ++k) if (rows[k].a === a) return rep.itemAt(k); return null }

  MouseArea { anchors.fill: parent; onPressed: fp.close(); onWheel: function (w) { w.accepted = true }; Accessible.ignored: true }

  Rectangle {
    id: panel
    width: 260
    height: col.height + 12
    radius: 10
    color: Theme.page
    border.width: Theme.hair
    border.color: Theme.separator
    activeFocusOnTab: false
    Accessible.role: Accessible.Dialog
    Accessible.name: "Filter conversations"
    Keys.onEscapePressed: fp.close()
    layer.enabled: true
    layer.effect: MultiEffect { shadowEnabled: true; shadowColor: "black"; shadowOpacity: Theme.dark ? 0.5 : 0.16; shadowBlur: 0.6; shadowVerticalOffset: 6 }
    MouseArea { anchors.fill: parent; Accessible.ignored: true }   // a press inside never closes it

    Column {
      id: col
      x: 6
      y: 6
      width: parent.width - 12
      Repeater {
        id: rep
        model: fp.rows
        delegate: Item {
          id: row
          readonly property bool sep: modelData.a === "-"
          readonly property bool isOn: sep ? false : fp.checked(modelData.a, fp.page.appFilter)
          readonly property bool live: !sep && !(modelData.a === "reset" && fp.page.appFilter.length === 0)
          width: col.width
          height: sep ? 9 : 28
          activeFocusOnTab: live
          Accessible.role: sep ? Accessible.Separator : (modelData.a === "reset" ? Accessible.Button : Accessible.CheckBox)
          Accessible.name: sep ? "" : modelData.t + (modelData.n >= 0 ? ", " + fp.page.num(modelData.n) : "")
          Accessible.checkable: !sep && modelData.a !== "reset"
          Accessible.checked: isOn
          Accessible.onPressAction: if (live) fp.act(modelData.a)
          Accessible.onToggleAction: if (live) fp.act(modelData.a)
          Keys.onSpacePressed: if (live) fp.act(modelData.a)
          Keys.onReturnPressed: if (live) fp.act(modelData.a)

          Rectangle { visible: row.sep; y: 4; width: parent.width; height: Theme.hair; color: Theme.separator }
          Rectangle {
            visible: !row.sep
            anchors.fill: parent
            radius: 6
            color: row.activeFocus && App.keyboardMode ? Theme.focusTint : Theme.rowHover
            opacity: row.live && (hover.hovered || (row.activeFocus && App.keyboardMode)) ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: Theme.dHover } }
          }
          Row {
            visible: !row.sep
            x: 8
            spacing: 6
            height: parent.height
            opacity: row.live ? 1 : 0.45
            Item {
              width: 14; height: 14; anchors.verticalCenter: parent.verticalCenter
              Icon { anchors.centerIn: parent; name: "check"; size: 12; color: Theme.label; opacity: row.isOn ? 1 : 0 }
            }
            ProviderTile { visible: !!modelData.p; provider: modelData.p || "codex"; size: 16; anchors.verticalCenter: parent.verticalCenter }
            Txt { leftPadding: modelData.indent ? 22 : 0; text: modelData.t || ""; anchors.verticalCenter: parent.verticalCenter }
          }
          Txt {
            visible: !row.sep && modelData.n >= 0
            x: parent.width - 8 - width
            anchors.verticalCenter: parent.verticalCenter
            role: "secondary"; tabular: true; color: Theme.secondary
            text: modelData.n >= 0 ? fp.page.num(modelData.n) : ""
          }
          HoverHandler { id: hover; enabled: !row.sep }
          MouseArea { anchors.fill: parent; enabled: row.live; onClicked: fp.act(modelData.a) }
        }
      }
    }
  }
}
