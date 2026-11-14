import QtQuick
import "Acc.js" as A

// Droid "Missions" card (accounts.md 6): title, divider, count; 36 high rows: title over
// "131 of 160 done · 26 cancelled · <owner> · Oct 17", then Resume and Start here.
Card {
  id: card
  property var ctl
  property var missions: []
  title: "Missions"
  accessory: [ Txt { role: "secondary"; tabular: true; color: Theme.secondary; text: String(card.missions.length) } ]

  function detail(m) {
    var left = (m.total || 0) - (m.completed || 0) - (m.cancelled || 0), parts = []
    parts.push(!m.total ? "No features yet" : (left <= 0 ? "Done" : m.completed + " of " + m.total + " done"))
    if (m.cancelled > 0) parts.push(m.cancelled + " cancelled")
    var owner = m.owner ? ctl.find(m.owner) : null
    parts.push(owner ? owner.label : "Owner unknown")
    if (m.createdAt) { var d = new Date(Date.parse(m.createdAt)); parts.push(A.MONTHS[d.getMonth()] + " " + d.getDate()) }
    return parts.join(" · ")
  }

  Repeater {
    model: card.missions
    delegate: Item {
      readonly property int remaining:(modelData.total || 0) - (modelData.completed || 0) - (modelData.cancelled || 0)
      readonly property var owner: modelData.owner ? card.ctl.find(modelData.owner) : null
      width: card.width
      height: index === card.missions.length - 1 ? 36 + 11 : 36
      Rectangle { visible: index > 0; x: 16; width: parent.width - 32; height: Theme.hair; color: Theme.tableSeparator }
      Column {
        x: 16
        y: (36 - height) / 2
        width: btns.x - 12 - 16
        Txt { text: modelData.title || "Mission"; width: parent.width; elide: Text.ElideRight }
        Txt { role: "secondary"; color: Theme.secondary; width: parent.width; elide: Text.ElideRight; text: card.detail(modelData) }
        ToolTipArea { text: (modelData.title || "Mission") + "\n" + card.detail(modelData) + (modelData.state ? "\nState: " + modelData.state : "") }
      }
      Row {
        id: btns
        x: parent.width - 16 - width
        y: 7
        spacing: 8
        PushButton { controlHeight: 22; text: "Resume"; minWidth: 64; enabled: !card.ctl.busy
                     onClicked: card.ctl.act("droid.resumeMission", { missionID: modelData.id }) }
        PushButton { controlHeight: 22; text: "Start here"; enabled: !card.ctl.busy
                     visible: parent.parent.remaining > 0 && (!parent.parent.owner || !parent.parent.owner.isDefault)
                     onClicked: card.ctl.act("droid.startMissionHere", { missionID: modelData.id }) }
        PushButton { id: mm; controlHeight: 22; square: true; icon: "ellipsis"; tip: "More actions for this mission"
                     Accessible.name: "More actions"; onClicked: card.ctl.missionMenu(mm, modelData) }
      }
    }
  }
}
