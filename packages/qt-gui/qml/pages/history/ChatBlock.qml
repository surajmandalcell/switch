import QtQuick

// One parsed block (history.md 2.3): paragraph, quote, lists, table, code, divider. Text is selectable;
// bullets, numbers, and rules are not.
Loader {
  id: bl
  property var block: ({})
  property bool bare: false
  property bool open: false
  signal toggle()
  signal copy(string text)
  width: parent ? parent.width : 0
  sourceComponent: ({ paragraph: para, heading: para, quote: quote, ul: ulist, ol: olist, table: table, code: code,
                      divider: divider })[block.type] || para

  Component { id: para; ChatText { width: bl.width; html: bl.block.html || ""; bold: bl.block.type === "heading" } }

  Component {
    id: quote
    Item {
      width: bl.width
      height: qt.height
      Rectangle { width: 2; height: parent.height; color: Theme.separator }
      ChatText { id: qt; x: 11; width: parent.width - 11; color: Theme.secondary; html: bl.block.html }
    }
  }

  Component {
    id: ulist
    Column {
      width: bl.width
      spacing: 5
      Repeater {
        model: bl.block.items
        Item {
          width: bl.width
          height: ut.height
          Txt { id: dotT; text: "•"; height: 20 }
          ChatText { id: ut; x: dotT.width + 8; width: parent.width - x; html: modelData }
        }
      }
    }
  }

  Component {
    id: olist
    Column {
      width: bl.width
      spacing: 5
      Repeater {
        model: bl.block.items
        Item {
          width: bl.width
          height: Math.max(24, ot.y + ot.height)
          Rectangle {
            width: 24; height: 24; radius: 4; color: Theme.tileFill
            Txt { anchors.centerIn: parent; tabular: true; text: (index + 1) + "." }
          }
          // first baselines line up: the badge text centers at 12, the first 20 pt text line at 10
          ChatText { id: ot; x: 24 + 8; y: 2; width: parent.width - x; html: modelData }
        }
      }
    }
  }

  Component {
    id: table
    Item {
      id: tb
      readonly property var headers: bl.block.headers
      readonly property bool kv: headers.length === 2
      // 3 or more columns: automatic layout like a SwiftUI Grid. Each column wants its widest unwrapped cell; a
      // fair share (avail / n) is granted first, then the rest goes to columns that want more, by how much more.
      readonly property var colW: kv ? [128, bl.width - 140] : layout()
      function plain(h) { return String(h).replace(/<[^>]*>/g, "").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&") }
      function layout() {
        var n = headers.length, avail = Math.max(0, bl.width - 12 * (n - 1)), want = [], k, r
        for (k = 0; k < n; ++k) want.push(Math.ceil(fmBold.advanceWidth(plain(headers[k]))) + 1)
        for (r = 0; r < bl.block.rows.length; ++r)
          for (k = 0; k < n; ++k) want[k] = Math.max(want[k], Math.ceil(fm.advanceWidth(plain(bl.block.rows[r][k] || ""))) + 1)
        var total = want.reduce(function (a, b) { return a + b }, 0)
        if (total <= avail) return want.map(function (w) { return w + (avail - total) * w / total })
        var fair = avail / n, got = want.map(function (w) { return Math.min(w, fair) })
        var left = avail - got.reduce(function (a, b) { return a + b }, 0)
        var need = want.map(function (w, i) { return w - got[i] }), needSum = need.reduce(function (a, b) { return a + b }, 0)
        return got.map(function (g, i) { return g + (needSum > 0 ? left * need[i] / needSum : 0) })
      }
      function cellX(c) { if (kv) return c === 0 ? 0 : 140; var x = 0; for (var k = 0; k < c; ++k) x += colW[k] + 12; return x }
      function cellW(c) { return colW[c] }
      FontMetrics { id: fm; font.family: Theme.fontFamily; font.pointSize: 13 * Theme.fontScale * 0.75 }
      FontMetrics { id: fmBold; font: Qt.font({ family: Theme.fontFamily, pointSize: 13 * Theme.fontScale * 0.75, weight: Font.Bold }) }
      width: bl.width
      height: tcol.height
      Column {
        id: tcol
        width: parent.width
        Repeater {
          model: [tb.headers].concat(bl.block.rows)
          Column {
            readonly property int row: index
            width: tcol.width
            Rectangle { visible: row > 0; width: parent.width; height: Theme.hair; color: Theme.separator }
            Item {
              width: parent.width
              height: cells.childrenRect.height
              Item {
                id: cells
                anchors.fill: parent
                Repeater {
                  model: modelData
                  Item {
                    x: tb.cellX(index)
                    width: tb.cellW(index)
                    height: ct.height + 12
                    ChatText { id: ct; y: 6; width: parent.width; html: modelData
                               bold: row === 0 ? !(tb.kv && index > 0) : (tb.kv && index === 0) }
                  }
                }
              }
            }
          }
        }
      }
      Rectangle { visible: tb.kv; x: 134; width: 1; height: parent.height; color: Theme.separator; opacity: 0.6 }
    }
  }

  Component { id: code; ChatCodeBlock { width: bl.width; block: bl.block; bare: bl.bare; open: bl.open
                                        onToggle: bl.toggle(); onCopy: function (t) { bl.copy(t) } } }

  Component { id: divider; Item { width: bl.width; height: Theme.hair + 4
                                  Rectangle { y: 2; width: parent.width; height: Theme.hair; color: Theme.separator } } }
}
