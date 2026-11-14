import QtQuick
import "Acc.js" as A

// ClaudeActivityPanel (accounts.md 2.10, PRV:216-262) from the `activity` topic: Today, Yesterday, Last 30 days
// (tokens and the API-equivalent cost), the 30-day chart, then the notes. Loading and absent: one dotted meter.
Card {
  id: card
  property var ctl
  property string provider: "claude-code"
  readonly property bool droid: provider === "droid"
  readonly property var act: ctl.topic("activity")
  readonly property var sum: act ? (droid ? act.droid : act.claude) : null
  readonly property bool loading: !!act && (droid ? act.droidLoading : act.claudeLoading) === true
  readonly property string tool: droid ? "Droid" : "Claude Code"
  title: droid ? "Droid activity (all accounts)" : "Claude Code activity (all profiles)"

  Repeater {
    model: card.sum ? card.sum.rows : []
    delegate: AccSecRow {
      Item {
        width: parent.width
        height: 18
        Txt { anchors.verticalCenter: parent.verticalCenter; text: modelData.label }
        Row {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: 12
          Txt { role: "secondary"; tabular: true; color: Theme.secondary; text: A.tokens(modelData.tokens) + " tokens" }
          Txt { role: "secondary"; tabular: true; color: Theme.secondary
                text: modelData.costUSD === null || modelData.costUSD === undefined ? "No price" : "≈ " + A.money(modelData.costUSD, "USD") }
        }
        ToolTipArea { text: modelData.detail || "" }
      }
    }
  }
  AccSecRow { visible: !!card.sum && !!card.sum.chart; AccChart { chart: card.sum && card.sum.chart ? card.sum.chart : ({ title: "", points: [] }) } }
  AccSecRow {
    visible: !!card.sum
    last: true
    Column {
      width: parent.width
      spacing: 4
      Txt { role: "secondary"; color: Theme.secondary; width: parent.width; wrapMode: Text.Wrap
            text: card.droid ? "API-equivalent estimate. Covers every Droid session on this computer, not only this account. A session counts on the day it was last active."
                             : "API-equivalent estimate. Covers every Claude Code profile on this computer, not only this account." }
      Txt { visible: !!card.sum && card.sum.unpricedModels.length > 0; role: "secondary"; color: Theme.secondary; width: parent.width; wrapMode: Text.Wrap
            text: card.sum ? "No price for " + card.sum.unpricedModels.join(", ") + ". Their cost is not included." : "" }
    }
  }
  AccSecRow {
    visible: !card.sum
    last: true
    AccMeter { ctl: card.ctl; w: null; title: "Usage"; provider: card.provider
               tip: card.loading ? (card.droid ? "Scanning local Droid sessions…" : "Scanning local Claude Code logs…")
                                 : card.tool + " activity is not available yet." }
  }
}
