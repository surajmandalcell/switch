import QtQuick
import QtQuick.Window

// The fixed 52 pt top bar of every page (shell.md 2.2): Add (28), More (28), Search (300 x 28), right aligned,
// 8 apart, right edge = page width - 20. The search text is one value for the whole window.
Item {
  id: hdr
  property string placeholder: "Search accounts and settings…"
  readonly property var win: Window.window
  height: 52
  function focusSearch() { search.focusInput() }

  Row {
    anchors.right: parent.right
    anchors.rightMargin: 20
    anchors.verticalCenter: parent.verticalCenter
    spacing: 8

    PushButton { square: true; icon: "plus"; tip: "Add Account"
                 enabled: !!Helper.topics.app && Helper.topics.app.hasLoaded && !Helper.topics.app.isBusy }
    PushButton {
      id: more
      square: true
      icon: "ellipsis"
      tip: "More"
      onClicked: Theme.menu.open(more, ["Refresh All Usage", "Add Account", "Import…", "-", "Settings"], -1, function (i) {
        if (i === 0) hdr.win.refreshAll()
        else if (i === 4) hdr.win.show(2)
      })
    }
    SearchField {
      id: search
      placeholder: hdr.placeholder
      text: hdr.win ? hdr.win.searchQuery : ""
      onTextChanged: if (hdr.win) hdr.win.searchQuery = text
    }
  }
}
