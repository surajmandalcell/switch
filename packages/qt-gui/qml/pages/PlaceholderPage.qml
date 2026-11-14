import QtQuick

// A page that a page worker has not built yet. It keeps the real header so the top bar never moves
// between pages, and names the spec file that describes the page.
Item {
  id: page
  property string title: ""
  property string spec: ""
  property string placeholder: "Search accounts and settings…"
  property alias header: header

  PageHeader { id: header; width: parent.width; placeholder: page.placeholder }
  Card {
    x: 20
    y: header.height + 12
    width: parent.width - 40
    title: page.title
    Item {
      width: parent.width
      height: 60
      Txt { x: 16; anchors.verticalCenter: parent.verticalCenter; role: "secondary"; color: Theme.secondary
            text: "This page is built from specs/port/" + page.spec + "." }
    }
  }
}
