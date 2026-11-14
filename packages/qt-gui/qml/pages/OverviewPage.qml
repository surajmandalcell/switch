import QtQuick
import "Data.js" as D

// Overview page (overview.md): the Usage card with four stat tiles and the Tokens per day card.
Item {
  id: page
  property alias header: header
  property alias scroll: scroll
  property alias chart: chart
  property int period: 0   // 0 week (default, overview.md 4), 1 month
  readonly property int count: period === 1 ? 30 : 7
  readonly property var ser: D.series(count)
  readonly property var tot: D.totals(ser)
  onVisibleChanged: if (visible) { scroll.appear(); chart.replay() }

  PageHeader { id: header; width: parent.width; placeholder: "Search accounts and settings…" }

  ScrollArea {
    id: scroll
    anchors.top: header.bottom
    anchors.bottom: parent.bottom
    width: parent.width
    gutter: 20

    Card {
      title: "Usage"
      note: page.period === 1 ? "(last 30 days)" : "(last 7 days)"
      divider: false
      accessory: [
        Segmented { model: ["Week", "Month"]; current: page.period; onPicked: function (i) { page.period = i } },
        Segmented { model: ["Accounts", "Models", "Projects"] }
      ]
      Item {
        width: parent.width
        height: 74 + 16
        Row {
          x: 16
          spacing: 12
          readonly property real tw: (parent.width - 32 - 36) / 4
          StatTile { width: parent.tw; label: "Tokens"; value: D.fmt(page.tot.sum); detail: "In the last " + page.count + " days" }
          StatTile {
            width: parent.tw; label: "Estimated cost"
            value: { var c = page.tot.sum / 1e6 * 2.5; return c >= 1000 ? "$" + (c / 1000).toFixed(1).replace(/\.0$/, "") + "K" : "$" + Math.round(c) }
            detail: "API-rate estimate, not billed"
          }
          StatTile { width: parent.tw; label: "Active accounts"; value: "3"; detail: "With usage in this period" }
          StatTile { width: parent.tw; label: "Busiest day"; value: D.shortDay(page.tot.busiest); detail: D.fmt(page.tot.busiestV) + " tokens" }
        }
      }
    }

    Card {
      title: "Tokens per day"
      note: "(by account)"
      Item {
        width: parent.width
        height: 14 + 220 + 10 + 18 + 14
        StreamChart {
          id: chart
          y: 14
          width: parent.width
          series: page.ser
        }
        Row {
          x: 16
          y: 14 + 220 + 10
          height: 18
          spacing: 14
          Repeater {
            model: page.ser
            delegate: Row {
              spacing: 6
              height: 18
              opacity: 1 - chart.engaged * (index === chart.hoverBand ? 0 : 0.62)
              Rectangle { anchors.verticalCenter: parent.verticalCenter; width: 8; height: 8; radius: 4; color: Theme.brand(modelData.id) }
              ProviderTile { anchors.verticalCenter: parent.verticalCenter; size: 13; provider: modelData.id }
              Txt { anchors.verticalCenter: parent.verticalCenter; role: "secondary"
                    color: index === chart.hoverBand && chart.engaged > 0.5 ? Theme.label : Theme.secondary; text: modelData.label }
            }
          }
        }
      }
    }
  }
}
