import QtQuick
import "Acc.js" as A

// FocusedAccountCard (accounts.md 2.10): tile 44, name (Title), provider + state badge; a hairline and the
// 300 wide usage block; then the action row: primary + Open on the left, Allow access, Copy and More right.
Card {
  id: card
  property var ctl
  property var row
  readonly property string pname: ctl.pname(row.providerID)
  readonly property var w: A.firstWindow(row)
  readonly property bool signedOut: A.needsSignIn(row)
  readonly property var stateBadge: {
    if (row.verification === "imported") return { t: "Check required", c: Theme.accent }
    if (row.verification === "needsSignIn" || row.needsSignIn) return { t: "Needs sign-in", c: Theme.amber }
    if (row.verification === "unsupported") return { t: "Unsupported", c: Theme.red }
    return null
  }
  Accessible.name: "Focused account"

  Item {
    width: parent.width
    height: 16 + top.height + 16 + 28 + 16
    Item {
      id: top
      x: 16
      y: 16
      width: parent.width - 32
      height: Math.max(44, block.height)
      ProviderTile { id: tile; size: 44; provider: card.row.providerID; name: card.pname; anchors.verticalCenter: parent.verticalCenter }
      Column {
        x: 44 + 12
        anchors.verticalCenter: parent.verticalCenter
        width: rule.x - x - 16
        spacing: 2
        Txt { id: nm; role: "title"; text: card.row.label; width: Math.min(implicitWidth, parent.width); elide: Text.ElideMiddle
              Accessible.role: Accessible.Heading; ToolTipArea { text: nm.truncated ? card.row.label : "" } }
        Row {
          height: 18
          spacing: 8
          Txt { anchors.verticalCenter: parent.verticalCenter; role: "secondary"; color: Theme.secondary; text: card.pname }
          Badge {
            readonly property var inc: card.ctl.incident(card.row.providerID)
            visible: !!inc
            anchors.verticalCenter: parent.verticalCenter
            text: "Incident"
            dot: Theme.amber
            Accessible.name: "Provider status"
            ToolTipArea { text: card.ctl.incidentText(parent.inc) }
          }
          Badge { visible: !!card.stateBadge; anchors.verticalCenter: parent.verticalCenter
                  text: card.stateBadge ? card.stateBadge.t : ""; dot: card.stateBadge ? card.stateBadge.c : Theme.green }
          Row {
            visible: !card.stateBadge && card.row.isDefault
            anchors.verticalCenter: parent.verticalCenter
            spacing: 5
            Rectangle { width: 8; height: 8; radius: 4; color: Theme.green; anchors.verticalCenter: parent.verticalCenter }
            Txt { role: "secondary"; color: Theme.secondary; text: "Active"; anchors.verticalCenter: parent.verticalCenter }
          }
        }
      }
      Rectangle { id: rule; x: block.x - 16 - width; width: Theme.hair; height: 44; anchors.verticalCenter: parent.verticalCenter; color: Theme.separator }

      // UsageWindowBlock (ACC:2077-2126): title + value, bar or dotted track, reset line.
      Column {
        id: block
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: 300
        spacing: 6
        Accessible.role: Accessible.StaticText
        Item {
          width: parent.width
          height: 18
          Txt { anchors.verticalCenter: parent.verticalCenter; text: card.w ? card.w.title : "Usage"; width: parent.width - val.width - 12; elide: Text.ElideRight }
          RollText {
            id: val
            visible: !!card.w
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            role: "body"
            text: card.w ? A.pctWord(card.w.usedPercent, Theme.showUsed) : ""
            activeFocusOnTab: visible
            Accessible.role: Accessible.Button
            Accessible.name: (card.w ? card.w.title + " " : "") + text
            Accessible.description: Theme.showUsed ? "Show the percentage left" : "Show the percentage used"
            Accessible.onPressAction: card.ctl.toggleShowUsed()
            Keys.onSpacePressed: card.ctl.toggleShowUsed()
            Keys.onReturnPressed: card.ctl.toggleShowUsed()
            FocusFill { anchors.margins: -3; radius: 4 }
            ToolTipArea { text: Theme.showUsed ? "Click to show the percentage left" : "Click to show the percentage used" }
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: card.ctl.toggleShowUsed() }
          }
          // plain Secondary text, as the Mac draws it (no pill)
          Txt { id: why; visible: !card.w; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                role: "secondary"; color: Theme.secondary; text: A.reason(card.row, card.pname, "short")
                ToolTipArea { text: why.text } }
        }
        UsageBar { width: parent.width; used: card.w ? card.w.usedPercent : -1; provider: card.row.providerID }
        Txt {
          id: rs
          height: 14
          visible: text !== ""   // the Mac block has no empty reset line, so title and track sit centered
          role: "secondary"
          color: Theme.secondary
          text: card.w && card.w.resetsAt ? A.resetText(card.w.resetsAt, card.ctl.now, card.w.usedPercent, card.ctl.exact, card.ctl.h24) : ""
          activeFocusOnTab: text !== ""
          Accessible.role: Accessible.Button
          Accessible.name: text
          Accessible.description: "Switch between countdown and exact time"
          Accessible.onPressAction: if (rs.text !== "") card.ctl.toggleExact()
          Keys.onSpacePressed: card.ctl.toggleExact()
          Keys.onReturnPressed: card.ctl.toggleExact()
          FocusFill { anchors.margins: -3; radius: 4 }
          ToolTipArea { text: rs.text !== "" ? rs.text + "\n" + A.resetText(card.w.resetsAt, card.ctl.now, card.w.usedPercent, !card.ctl.exact, card.ctl.h24) : "" }
          MouseArea { anchors.fill: parent; enabled: rs.text !== ""; cursorShape: Qt.PointingHandCursor; onClicked: card.ctl.toggleExact() }
        }
      }
    }

    // Action row (ACC:1468-1520)
    Row {
      x: 16
      y: top.y + top.height + 16
      spacing: 8
      PushButton {
        text: card.signedOut ? "Sign in again" : (card.row.isDefault ? "Using as default" : "Make Default")
        prominent: card.signedOut || !card.row.isDefault
        enabled: card.signedOut ? !card.ctl.busy : (!card.row.isDefault && !card.ctl.busy && A.canSwitch(card.row))
        Accessible.description: card.row.isDefault && !card.signedOut ? "This account is already the default." : ""
        onClicked: card.signedOut ? card.ctl.signIn(card.row) : card.ctl.switchDefault(card.row)
      }
      PushButton {
        visible: A.isBuiltIn(card.row.providerID)
        icon: "play"
        text: (card.row.isDefault ? "Open " : "Use & Open ") + A.toolName(card.row.providerID, card.ctl.names)
        enabled: !card.ctl.busy
        onClicked: card.ctl.openAccount(card.row)
      }
      PushButton {
        readonly property string url: { var p = card.ctl.provider(card.row.providerID); return p && p.dashboard ? p.dashboard : "" }
        visible: !A.isBuiltIn(card.row.providerID) && url !== ""
        icon: "arrowRight"
        text: "Open dashboard"
        onClicked: Qt.openUrlExternally(url)
      }
    }
    Row {
      anchors.right: parent.right
      anchors.rightMargin: 16
      y: top.y + top.height + 16
      spacing: 8
      PushButton { visible: !!card.row.needsDroidAccess; text: "Allow access"; tip: "Allow Switch to read Droid's login for usage"
                   enabled: !card.ctl.busy && !card.row.isRefreshing; onClicked: card.ctl.allow(card.row) }
      PushButton { icon: "copy"; text: "Copy"; tip: "Copy the account name"; onClicked: card.ctl.copyName(card.row) }
      PushButton { id: more; square: true; icon: "ellipsis"; tip: "More actions for this account"; Accessible.name: "More actions"
                   onClicked: card.ctl.moreMenu(card.row, more) }
    }
  }
}
