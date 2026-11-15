import QtQuick

// DroidUsageKeyPanel (accounts.md 2.10, PRV:5-28): "Factory usage key" with a secure field, a note, and
// Save key / Remove key through droid.setUsageKey. The key never comes back; only its presence does.
Card {
  id: card
  property var ctl
  property var row
  readonly property bool hasKey: row.hasUsageKey === true
  title: "Factory usage key"

  AccSecRow {
    last: true
    Column {
      width: parent.width
      spacing: 8
      FieldBox { id: key; width: parent.width; secure: true; placeholder: "Factory API key"
                 Accessible.description: "Factory API key for this Droid account"
                 Keys.onReturnPressed: save.clicked() }
      Txt { role: "secondary"; color: Theme.secondary; width: parent.width; wrapMode: Text.Wrap
            text: "An API key shows usage without opening or decrypting the Droid login." }
      Row {
        spacing: 8
        PushButton {
          id: save
          text: "Save key"
          enabled: !card.ctl.busy && key.text.trim() !== ""
          onClicked: { var k = key.text.trim(); key.text = ""; card.ctl.act("droid.setUsageKey", { accountID: card.row.id, key: k }) }
        }
        PushButton {
          text: "Remove key"
          enabled: !card.ctl.busy && card.hasKey
          onClicked: card.ctl.act("droid.setUsageKey", { accountID: card.row.id, key: "" })
        }
      }
    }
  }
}
