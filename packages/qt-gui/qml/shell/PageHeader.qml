import QtQuick
import QtQuick.Window

// The fixed 52 pt top bar of every page (shell.md 2.2): Add (28), More (28), Search (300 x 28), right aligned,
// 8 apart, right edge = page width - 20. The search text is one value for the whole window.
Item {
  id: hdr
  property string placeholder: "Search accounts and settings…"
  readonly property var win: Window.window
  // The helper's notices.error under the top bar on every page (shell.md 2.2 Error bar, rpc.md "Every page");
  // Accounts turns this off because it merges the topic with its own action errors.
  property bool showsNotices: true
  readonly property string noticeError: showsNotices && Helper.topics.notices ? (Helper.topics.notices.error || "") : ""
  height: 52 + (errBar.visible ? errBar.height + 12 : 0)
  objectName: "page-header"
  Accessible.role: Accessible.ToolBar
  Accessible.name: "Toolbar"
  function focusSearch() { search.focusInput() }

  AccErrorBar {
    id: errBar
    visible: hdr.noticeError !== ""
    x: 20
    y: 52
    width: parent.width - 40
    text: hdr.noticeError
    onDismiss: Helper.call("notices.dismiss", { which: "error" }, function () {})
    onCopy: App.copy(hdr.noticeError)
  }

  Row {
    y: (52 - height) / 2
    anchors.right: parent.right
    anchors.rightMargin: 20
    spacing: 8

    // AIMAddAccountButton: a square "+" on every page, widened into "+ Add Account" while Accounts shows.
    // Every page keeps its own header, so each one follows the shown page, also while hidden: leaving
    // Accounts finds the next page's button wide, and it narrows in view (0.32 s spring; instant without motion).
    PushButton {
      id: add
      objectName: "add-account"
      tip: "Add Account"
      enabled: !!Helper.topics.app && Helper.topics.app.hasLoaded && !Helper.topics.app.isBusy
      onClicked: hdr.win.openAccountSheet("add")
      readonly property bool wide: !!hdr.win && hdr.win.pages[hdr.win.pageIndex].route === "Accounts"
      readonly property real t: Math.max(0, Math.min(1.2, grow.value))
      onWideChanged: if (Theme.motion && !Theme.reduceMotion) grow.target = wide ? 1 : 0; else grow.snap(wide ? 1 : 0)
      Component.onCompleted: grow.snap(wide ? 1 : 0)
      SpringValue { id: grow; duration: 0.32; bounce: 0.12 }
      width: 28 + t * (5 + label.implicitWidth + 10)
      clip: true
      Icon { x: 7 + Math.min(1, add.t) * 5; anchors.verticalCenter: parent.verticalCenter; name: "plus"; size: 14
             color: add.textColor; opacity: add.enabled ? 1 : 0.45 }
      Txt { id: label; x: 7 + 5 + 14 + 5; anchors.verticalCenter: parent.verticalCenter; text: "Add Account"
            color: add.textColor; opacity: Math.min(1, add.t) * (add.enabled ? 1 : 0.45) }
    }
    PushButton {
      id: more
      square: true
      icon: "ellipsis"
      tip: "More"
      Accessible.role: Accessible.ButtonMenu
      onClicked: Theme.menu.open(more, ["Refresh All Usage", "Add Account", "Import…", "-", "Settings"], -1, function (i) {
        if (i === 0) hdr.win.refreshAll()
        else if (i === 1) hdr.win.openAccountSheet("add")
        else if (i === 2) hdr.win.openAccountSheet("import")
        else if (i === 4) hdr.win.show(2)
      })
    }
    SearchField {
      id: search
      placeholder: hdr.placeholder
      text: hdr.win ? hdr.win.searchQuery : ""
      onTextChanged: if (hdr.win) hdr.win.searchQuery = text
      arrowKeys: !!hdr.win && hdr.win.dropdownPage
      onInputFocusedChanged: if (hdr.win) hdr.win.searchFocused = inputFocused
      onMoved: function (d) { hdr.win.searchMove(d) }
      onAccepted: hdr.win.searchAccept()
    }
  }
}
