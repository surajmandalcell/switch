import QtQuick
import "Acc.js" as A

// "Daily activity" (UsageActivityCalendar, accounts.md 2.11, ACC:471-726): selected day and its tokens | period
// pop-up (key usageTokenPeriod, default Yearly); the period's token total; 7 days or fewer as one row of 18 cells,
// longer as a Sunday-first heatmap (7 rows, 3 gaps, M/W/F gutter). Selecting a day lists its projects.
Card {
  id: card
  property var ctl
  property string accountID: ""
  property var rows: []            // usage.detail `daily`: [{startDate "yyyy-MM-dd", tokens}]
  title: "Daily activity"

  readonly property var periods: ["Today", "Yesterday", "Weekly", "Monthly", "Yearly"]
  readonly property int period: Math.max(0, periods.indexOf(String(ctl.pref("usageTokenPeriod", "Yearly"))))
  readonly property int count: [1, 1, 7, 30, 365][period]
  function iso(d) { return d.toISOString().slice(0, 10) }
  // UTC days, oldest first; Yesterday ends yesterday
  readonly property var days: {
    var m = {}
    rows.forEach(function (r) { if (r.startDate) m[String(r.startDate).slice(0, 10)] = (m[String(r.startDate).slice(0, 10)] || 0) + (r.tokens || 0) })
    var end = new Date(Math.floor(ctl.now / 86400000) * 86400000 - (period === 1 ? 86400000 : 0)), out = []
    for (var i = count - 1; i >= 0; --i) { var d = new Date(end.getTime() - i * 86400000); out.push({ day: iso(d), date: d, tokens: m[iso(d)] || 0 }) }
    return out
  }
  readonly property real maxTokens: days.reduce(function (s, d) { return Math.max(s, d.tokens) }, 0)
  readonly property real total: days.reduce(function (s, d) { return s + d.tokens }, 0)
  property int sel: -1
  property var projects: null
  onAccountIDChanged: { sel = -1; projects = null }
  onSelChanged: {
    projects = null
    if (sel < 0 || sel >= days.length) return
    var day = days[sel].day
    Helper.call("usage.projectActivity", { day: day }, function (r, e) { if (!e && card.sel >= 0 && card.days[card.sel].day === day) card.projects = r || [] })
  }
  function cellColor(t) { return t <= 0 ? Theme.usageTrack : Qt.rgba(Theme.green.r, Theme.green.g, Theme.green.b, 0.24 + 0.70 * Math.sqrt(t / Math.max(1, maxTokens))) }
  function longDay(d) { return ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][d.getUTCDay()] + ", "
                               + A.MONTHS_LONG[d.getUTCMonth()] + " " + d.getUTCDate() + ", " + d.getUTCFullYear() }
  function move(step) { sel = sel < 0 ? days.length - 1 : Math.max(0, Math.min(days.length - 1, sel + step)) }

  AccSecRow {
    last: !card.projects
    Column {
      width: parent.width
      spacing: 8
      Item {
        width: parent.width
        height: 28
        Row {
          anchors.verticalCenter: parent.verticalCenter
          spacing: 8
          visible: card.sel >= 0
          Txt { role: "secondary"; color: Theme.secondary; anchors.verticalCenter: parent.verticalCenter
                text: card.sel >= 0 ? A.MONTHS[card.days[card.sel].date.getUTCMonth()] + " " + card.days[card.sel].date.getUTCDate() + ", " + card.days[card.sel].date.getUTCFullYear() : "" }
          Txt { tabular: true; anchors.verticalCenter: parent.verticalCenter; text: card.sel >= 0 ? A.group3(card.days[card.sel].tokens) + " tokens" : "" }
        }
        PopUp { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; name: "Token period"
                options: card.periods; current: card.period; onPicked: function (i) { Prefs.set("usageTokenPeriod", card.periods[i]); card.sel = -1 } }
      }
      Row {
        spacing: 4
        Txt { tabular: true; font.family: "monospace"; text: A.tokens(card.total) }
        Txt { role: "secondary"; color: Theme.secondary; text: "tokens"; anchors.baseline: parent.children[0].baseline }
      }
      // grid: one row for short periods, else weeks as columns
      Item {
        id: grid
        width: parent.width
        // Not "short": Qt 6.10's QML compiler reads it as a reserved word.
        readonly property bool oneRow: card.count <= 7
        readonly property int pad: card.days.length ? card.days[0].date.getUTCDay() : 0
        readonly property int weeks: Math.ceil((pad + card.days.length) / 7)
        readonly property real cell: {
          if (oneRow) return 18
          var sizes = card.period === 4 ? [9, 8, 7, 6, 5] : [13, 9, 8, 7, 6, 5]
          for (var i = 0; i < sizes.length; ++i) if (15 + weeks * (sizes[i] + 3) <= width) return sizes[i]
          return 5
        }
        height: oneRow ? 14 + 5 + 18 : 7 * (cell + 3)
        activeFocusOnTab: true
        Keys.onLeftPressed: card.move(oneRow ? -1 : -7)
        Keys.onRightPressed: card.move(oneRow ? 1 : 7)
        Keys.onUpPressed: card.move(-1)
        Keys.onDownPressed: card.move(1)
        Accessible.role: Accessible.Table
        Accessible.name: "Daily token activity"
        FocusFill { anchors.margins: -4; radius: 6 }

        Repeater {
          model: grid.oneRow ? card.days : []
          delegate: Column {
            x: index * (18 + 6)
            spacing: 5
            Txt { role: "caption"; color: Theme.secondary; width: 18; horizontalAlignment: Text.AlignHCenter
                  text: ["S", "M", "T", "W", "T", "F", "S"][modelData.date.getUTCDay()] }
            Rectangle {
              width: 18; height: 18; radius: Math.max(1, 18 * 0.18)
              color: card.cellColor(modelData.tokens)
              border.width: card.sel === index ? 1 : 0
              border.color: Theme.label
              ToolTipArea { text: card.longDay(modelData.date) + ": " + A.group3(modelData.tokens) + " tokens" }
              MouseArea { anchors.fill: parent; onClicked: card.sel = index }
            }
          }
        }
        Repeater {
          model: grid.oneRow ? [] : ["M", "W", "F"]
          delegate: Txt { y: (1 + index * 2) * (grid.cell + 3) + (grid.cell - height) / 2; role: "caption"; color: Theme.secondary; text: modelData; font.pixelSize: Math.min(9, grid.cell + 1) }
        }
        Repeater {
          model: grid.oneRow ? [] : card.days
          delegate: Rectangle {
            readonly property int slot: grid.pad + index
            x: 15 + Math.floor(slot / 7) * (grid.cell + 3)
            y: (slot % 7) * (grid.cell + 3)
            width: grid.cell; height: grid.cell
            radius: Math.max(1, grid.cell * 0.18)
            color: card.cellColor(modelData.tokens)
            border.width: card.sel === index ? 1 : 0
            border.color: Theme.label
            Rectangle { anchors.fill: parent; radius: parent.radius; color: Theme.ink(0.07); visible: hov.hovered }
            HoverHandler { id: hov }
            ToolTipArea { text: card.longDay(modelData.date) + ": " + A.group3(modelData.tokens) + " tokens" }
            MouseArea { anchors.fill: parent; onClicked: card.sel = index }
          }
        }
      }
    }
  }
  // the selected day's projects (usage.projectActivity)
  AccSecRow {
    visible: !!card.projects
    last: true
    Column {
      width: parent.width
      spacing: 6
      Txt { role: "secondary"; color: Theme.secondary; text: "Projects in this Codex home"
            ToolTipArea { text: "Recorded from local conversation token events. These shared-home totals are separate from account usage." } }
      Txt { visible: !!card.projects && card.projects.length === 0; role: "secondary"; color: Theme.secondary; text: "No projects on this day." }
      Repeater {
        model: card.projects || []
        delegate: Item {
          width: parent.width
          height: 18
          Txt { width: parent.width - right.width - 12; elide: Text.ElideMiddle; text: modelData.project; font.family: String(modelData.project).charAt(0) === "/" ? "monospace" : Theme.fontFamily
                role: "secondary"; anchors.verticalCenter: parent.verticalCenter
                MouseArea { anchors.fill: parent; enabled: String(modelData.project).charAt(0) === "/"; cursorShape: Qt.PointingHandCursor; onClicked: card.ctl.copy(modelData.project) }
                ToolTipArea { text: String(modelData.project).charAt(0) === "/" ? "Click to copy " + modelData.project : modelData.project } }
          Row {
            id: right
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: 6
            Txt { role: "secondary"; tabular: true; color: Theme.secondary; text: A.group3(modelData.tokens) + " tokens" }
            Icon { id: warn; visible: modelData.isComplete === false; name: "info"; size: 12; color: Theme.amber
                   ToolTipArea { text: "Some source records are incomplete. Previously recorded totals were retained." } }
          }
        }
      }
    }
  }
}
