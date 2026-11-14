import QtQuick
import "MaintFmt.js" as F

// Restore sheet (maintenance.md 2.5): 520 wide, as tall as its content. Whole backup or chosen top-level
// groups; back to the original place (after a safety snapshot) or into a folder.
MaintModal {
  id: sh
  property var request: null          // {snapshot, set, title}
  property bool restoring: false
  property var page: null
  property bool whole: true
  property bool inPlace: true
  property var chosen: ({})
  property int rev: 0
  property string folder: ""
  signal restore(var items, string destination)
  panelWidth: 520
  fill: Theme.page
  onCancelled: if (!restoring) open = false
  onReturned: if (ready) go()     // Return is the default button (Restore), as in a Mac sheet
  function go() { restore(whole ? null : Object.keys(chosen).sort(), (inPlace && !promptBackup) ? "" : folder) }
  onRequestChanged: if (request) { whole = true; inPlace = true; chosen = {}; folder = ""; ++rev }

  readonly property var snap: request ? request.snapshot : null
  readonly property bool promptBackup: !!snap && snap.promptsOnly === true
  // shortcut: groups come from snapshot.groups, a field backup.history does not send yet (see Helper needs)
  readonly property var groups: snap && snap.groups ? snap.groups.slice().sort(function (a, b) { return a.id < b.id ? -1 : 1 }) : []
  readonly property int chosenCount: { var r = rev; return Object.keys(chosen).length }
  readonly property bool ready: (whole || chosenCount > 0) && ((inPlace && !promptBackup) || folder !== "") && !restoring

  Column {
    width: parent.width
    Column {
      x: 20
      width: parent.width - 40
      topPadding: 20
      bottomPadding: 20
      spacing: 16
      Column {
        spacing: 2
        width: parent.width
        Txt { role: "section"; text: "Restore a backup" }
        Txt { width: parent.width; role: "secondary"; color: Theme.secondary; tabular: true; elide: Text.ElideRight
              text: sh.request ? sh.request.title + " · " + F.dateTime(sh.snap.date) + " · " + F.num(sh.snap.files) + " files" : "" }
      }
      Segmented {
        name: "What to restore"
        model: ["Whole backup", "Chosen items"]
        segmentWidth: 140
        current: sh.whole ? 0 : 1
        onPicked: function (i) { sh.whole = i === 0; current = Qt.binding(function () { return sh.whole ? 0 : 1 }) }
      }
      Flickable {
        id: groupList
        visible: !sh.whole
        width: parent.width
        height: visible ? Math.min(sh.groups.length, 6) * 26 - (sh.groups.length > 6 ? 0 : 8) : 0
        contentHeight: groupCol.height
        clip: sh.groups.length > 6
        interactive: sh.groups.length > 6
        boundsBehavior: Flickable.StopAtBounds
        opacity: visible ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.dState } }
        Column {
          id: groupCol
          width: parent.width
          spacing: 8
          Repeater {
            model: sh.groups
            delegate: Item {
              width: groupCol.width - (sh.groups.length > 6 ? 10 : 0)
              height: 18
              readonly property string name: F.label(modelData.id)
              MaintCheck { anchors.verticalCenter: parent.verticalCenter; label: parent.name; value: sh.rev >= 0 && sh.chosen[modelData.id] ? 2 : 0
                           onClicked: { if (sh.chosen[modelData.id]) delete sh.chosen[modelData.id]; else sh.chosen[modelData.id] = true; ++sh.rev }
                           onActiveFocusChanged: if (activeFocus) {   // keep the focused row in the scrolled list
                             var y = parent.y, fl = groupList
                             if (y < fl.contentY) fl.contentY = y
                             else if (y + parent.height > fl.contentY + fl.height) fl.contentY = y + parent.height - fl.height
                           } }
              Txt { x: 22; anchors.verticalCenter: parent.verticalCenter; width: parent.width - x - 8 - info.width; text: parent.name; elide: Text.ElideMiddle
                    ToolTipArea { text: parent.text } }
              Txt { id: info; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; role: "secondary"; color: Theme.secondary; tabular: true
                    text: F.num(modelData.files) + " files · " + F.size(modelData.bytes) }
            }
          }
        }
      }
      Hair { width: parent.width }
      Txt { role: "section"; text: "Restore to" }
      Segmented {
        visible: !sh.promptBackup
        name: "Where to restore"
        model: ["Original place", "A folder"]
        segmentWidth: 140
        current: sh.inPlace ? 0 : 1
        onPicked: function (i) { sh.inPlace = i === 0; current = Qt.binding(function () { return sh.inPlace ? 0 : 1 }) }
      }
      Txt {
        visible: sh.inPlace && !sh.promptBackup
        width: parent.width
        role: "secondary"; color: Theme.secondary; wrapMode: Text.Wrap
        text: "Switch first saves a safety backup of the files it replaces. Newer files that are not in this backup stay where they are."
      }
      Row {
        visible: !sh.inPlace || sh.promptBackup
        spacing: 8
        width: parent.width
        PushButton { id: pickBtn; text: sh.folder === "" ? "Choose a folder" : "Change"; icon: "folder"
                     onClicked: sh.page.pickFolder("Restore into a folder", "Restore", "", function (p) { sh.folder = p }) }
        MaintCopyPath { visible: sh.folder !== ""; anchors.verticalCenter: parent.verticalCenter; width: Math.min(implicitWidth, parent.width - pickBtn.width - 8); path: sh.folder }
      }
      Txt { visible: !sh.inPlace || sh.promptBackup; role: "secondary"; color: Theme.secondary; text: "The original files are not touched." }
    }
    Hair { width: parent.width }
    Item {
      width: parent.width
      height: 16 + 28 + 16
      MaintSpinner { x: 16; anchors.verticalCenter: parent.verticalCenter; visible: sh.restoring }
      Row {
        anchors.right: parent.right
        anchors.rightMargin: 16
        anchors.verticalCenter: parent.verticalCenter
        spacing: 8
        PushButton { text: "Cancel"; enabled: !sh.restoring; onClicked: sh.open = false }
        PushButton { text: "Restore"; prominent: true; enabled: sh.ready
                     onClicked: sh.go() }
      }
    }
  }
}
