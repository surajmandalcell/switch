import QtQuick

// "Account data needs repair" (accounts.md 2.10, ACC:255-276): one row per linked-setting divergence of this
// account: amber warning | the relative and local paths (click to copy) | copy warning | "Back up and repair".
Card {
  id: card
  property var ctl
  property var items: []
  title: "Account data needs repair"

  Repeater {
    model: card.items
    delegate: AccSecRow {
      last: index === card.items.length - 1
      Item {
        width: parent.width
        height: Math.max(paths.height, 28)
        Icon { id: warn; anchors.verticalCenter: parent.verticalCenter; name: "warnFill"; size: 14; color: Theme.amber }
        Column {
          id: paths
          x: warn.width + 10
          width: parent.width - x - btns.width - 12
          anchors.verticalCenter: parent.verticalCenter
          spacing: 2
          AccFact { width: parent.width; ctl: card.ctl; label: "Setting"; value: modelData.relativePath }
          AccFact { width: parent.width; ctl: card.ctl; label: "Location"; value: modelData.localPath }
        }
        Row {
          id: btns
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: 8
          AccCopyIcon {
            anchors.verticalCenter: parent.verticalCenter
            tip: "Copy repair warning"
            onCopy: card.ctl.copy("Account data needs repair: " + modelData.relativePath + "\nLocation: " + modelData.localPath)
          }
          PushButton {
            text: "Back up and repair"
            textColor: Theme.red
            enabled: !card.ctl.busy
            onClicked: card.ctl.act("accounts.repairLink", { accountID: modelData.accountID, relativePath: modelData.relativePath,
                                                             fingerprint: modelData.fingerprint })
          }
        }
      }
    }
  }
}
