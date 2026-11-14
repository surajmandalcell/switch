import QtQuick
import "Acc.js" as A

// ProviderUsagePanel (account-window.md 3.8): "Usage" card. Accessory: "Updated"/"Outdated" + time, copy,
// refresh (spinner while refreshing); without usage the reason, "Check again" and "Copy reason". Body:
// window meters, cost lines, charts, detail sections, the hidden-rows note; else placeholder meters.
Card {
  id: card
  property var ctl
  property var row
  property var detail: null
  readonly property string pname: ctl.pname(row.providerID)
  readonly property bool signedOut: A.needsSignIn(row)
  readonly property var usage: signedOut ? null : (detail && detail.usage ? detail.usage : null)
  readonly property var hidden: ctl.hiddenRows(row.id)
  readonly property var windows: signedOut ? [] : (usage ? (usage.windows || []).filter(function (w) { return card.hidden.indexOf(w.id) < 0 }) : (row.windows || []))
  readonly property var cost: usage && usage.cost && (usage.cost.used != null || usage.cost.balance != null || usage.cost.limit != null) ? usage.cost : null
  readonly property var sections: usage ? (usage.sections || []).filter(function (s) { return s.rows && s.rows.length }) : []
  readonly property var charts: usage ? (usage.charts || []).filter(function (c) { return c.points && c.points.length }) : []
  readonly property bool noPlan: !!usage && usage.availability === "noPlan"
  // Codex: the app-server snapshot (buckets, monthly credits) replaces the topic windows when it is there
  readonly property var codex: !signedOut && detail && detail.codex ? detail.codex : null
  readonly property bool hasUsage: codex ? A.codexHasLimits(codex)
                                         : !signedOut && !noPlan && (windows.some(A.hasValue) || !!cost || sections.length > 0 || charts.length > 0)
  readonly property string fetched: (codex && codex.fetchedAt) || (usage && usage.fetchedAt) || row.fetchedAt || ""
  readonly property string why: A.reason(noPlan ? Object.assign({ availability: "noPlan" }, row) : row, pname, "full")
  readonly property var items: {
    var out = []
    if (codex && hasUsage) {
      out = A.codexItems(codex, hidden)
      if (hidden.length) out.push({ k: "hidden" })
      return out
    }
    if (codex) return [{ k: "codexph" }]
    if (!hasUsage) {
      var t = A.emptyTitles(row.providerID, [])
      for (var i = 0; i < t.length; ++i) out.push({ k: "ph", title: t[i] })
      return out
    }
    windows.forEach(function (w) { out.push({ k: "meter", w: w }) })
    if (cost) out.push({ k: "cost" })
    charts.forEach(function (c) { out.push({ k: "chart", c: c }) })
    sections.forEach(function (s) { out.push({ k: "section", s: s }) })
    if (hidden.length) out.push({ k: "hidden" })
    return out
  }
  title: "Usage"

  accessory: [
    Txt {
      visible: card.hasUsage
      anchors.verticalCenter: parent.verticalCenter
      role: "secondary"
      color: card.row.error ? Theme.amber : Theme.secondary
      text: card.row.error ? "Outdated" : "Updated"
      ToolTipArea { text: card.row.error || "" }
    },
    Txt {
      visible: card.hasUsage && card.fetched !== ""
      anchors.verticalCenter: parent.verticalCenter
      role: "secondary"
      tabular: true
      color: card.row.error ? Theme.amber : Theme.secondary
      text: card.fetched !== "" ? A.clock(new Date(Date.parse(card.fetched)), card.ctl.h24) : ""
    },
    Txt {
      visible: !card.hasUsage
      anchors.verticalCenter: parent.verticalCenter
      width: Math.min(implicitWidth, 420)
      role: "secondary"
      color: Theme.secondary
      elide: Text.ElideMiddle
      horizontalAlignment: Text.AlignRight
      text: card.why
      ToolTipArea { text: card.why }
    },
    AccCopyIcon {
      visible: card.hasUsage ? !!card.row.error : true
      anchors.verticalCenter: parent.verticalCenter
      tip: card.hasUsage ? "Copy usage error" : "Copy reason"
      onCopy: card.ctl.copy(card.hasUsage ? card.row.error : card.why)
    },
    Item {
      width: 14
      height: 14
      anchors.verticalCenter: parent.verticalCenter
      AccSpinner { anchors.centerIn: parent; visible: !!card.row.isRefreshing; Accessible.name: "Refreshing usage" }
      IconButton {
        visible: !card.row.isRefreshing
        icon: "refresh"
        tip: card.hasUsage ? "Refresh usage" : "Check again"
        enabled: !card.ctl.busy
        onClicked: card.ctl.refresh(card.row)
      }
    }
  ]

  Repeater {
    model: card.items
    delegate: AccSecRow {
      last: index === card.items.length - 1
      Loader {
        width: parent.width
        sourceComponent: modelData.k === "meter" ? meterC : modelData.k === "ph" ? phC : modelData.k === "cost" ? costC
                       : modelData.k === "chart" ? chartC : modelData.k === "section" ? sectionC
                       : modelData.k === "bucket" ? bucketC : modelData.k === "codexph" ? codexPhC : hiddenC
        property var it: modelData
      }
    }
  }

  Component { id: meterC; AccMeter { ctl: card.ctl; w: parent.it.w; provider: card.row.providerID } }
  Component { id: phC; AccMeter { ctl: card.ctl; w: null; title: parent.it.title; provider: card.row.providerID; tip: parent.it.tip || card.why } }
  // Codex bucket (UsageBucket, ACC:876-927): title (Section) | model (mono) | flex | plan; meters; Credits, Spend control
  Component {
    id: bucketC
    Column {
      readonly property var b: parent.it
      spacing: 8
      Item {
        width: parent.width
        height: 18
        Row {
          spacing: 8
          anchors.verticalCenter: parent.verticalCenter
          Txt { role: "section"; text: b.title; ToolTipArea { text: b.title } }
          Txt { visible: b.model !== ""; role: "secondary"; color: Theme.secondary; font.family: "monospace"; text: b.model
                anchors.verticalCenter: parent.verticalCenter; ToolTipArea { text: b.model } }
        }
        Txt { visible: b.plan !== ""; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; role: "secondary"; color: Theme.secondary; text: b.plan }
      }
      Repeater { model: b.meters; delegate: AccMeter { width: parent.width; ctl: card.ctl; w: modelData; provider: "codex" } }
      Repeater { model: b.kv; delegate: AccFact { width: parent.width; label: modelData.label; value: modelData.value } }
    }
  }
  // Codex without a snapshot or limits: sub-header "Codex", then dotted Session and Weekly
  Component {
    id: codexPhC
    Column {
      spacing: 8
      Txt { role: "section"; text: "Codex" }
      AccMeter { width: parent.width; ctl: card.ctl; w: null; title: "Session"; provider: "codex"; tip: card.why }
      AccMeter { width: parent.width; ctl: card.ctl; w: null; title: "Weekly"; provider: "codex"; tip: card.why }
    }
  }
  Component { id: chartC; AccChart { chart: parent.it.c } }
  Component {
    id: costC
    Column {
      spacing: 8
      // {} while the Loader swaps away after cost goes null, so the bindings below never read null
      readonly property var c: card.cost || ({})
      readonly property string per: c.period ? " · " + c.period : ""
      AccFact { visible: c.used != null; label: "Spent" + parent.per
                value: c.used != null ? A.money(c.used, c.currency) + (c.limit != null ? " of " + A.money(c.limit, c.currency) : "") : "" }
      AccFact { visible: c.used == null && c.limit != null; label: "Limit" + parent.per; value: A.money(c.limit, c.currency) }
      AccFact { visible: c.balance != null; label: "Balance"; value: A.money(c.balance, c.currency) }
      AccFact {
        visible: !!c.resetsAt
        label: "Resets"
        clickable: true
        tip: "Click to switch between countdown and exact time"
        value: c.resetsAt ? A.resetText(c.resetsAt, card.ctl.now, 1, card.ctl.exact, card.ctl.h24).replace(/^Resets /, "") : ""
        onClicked: card.ctl.toggleExact()
      }
    }
  }
  Component {
    id: sectionC
    Column {
      spacing: 6
      readonly property var s: parent.it.s
      Txt { visible: !!parent.s.title; role: "secondary"; color: Theme.secondary; text: parent.s.title || "" }
      Repeater {
        model: parent.s.rows
        delegate: Item {
          width: parent.width
          height: 18
          Txt { anchors.verticalCenter: parent.verticalCenter; text: modelData.label; width: Math.min(implicitWidth, parent.width * 0.5); elide: Text.ElideRight }
          UsageBar {
            visible: modelData.progress !== undefined && modelData.progress !== null
            width: 56
            anchors.right: val.left
            anchors.rightMargin: 16
            anchors.verticalCenter: parent.verticalCenter
            used: (1 - (modelData.progress || 0)) * 100
            provider: card.row.providerID
          }
          Txt { id: val; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; role: "secondary"; tabular: true; color: Theme.secondary; text: modelData.value
                width: Math.min(implicitWidth, parent.width * 0.4); elide: Text.ElideMiddle; horizontalAlignment: Text.AlignRight }
        }
      }
    }
  }
  Component {
    id: hiddenC
    Item {
      height: 28
      Txt { anchors.verticalCenter: parent.verticalCenter; role: "secondary"; color: Theme.secondary
            text: A.plural(card.hidden.length, "hidden row", "hidden rows") }
      PushButton { anchors.right: parent.right; text: "Show all"; onClicked: card.ctl.showAllRows(card.row) }
    }
  }
}
