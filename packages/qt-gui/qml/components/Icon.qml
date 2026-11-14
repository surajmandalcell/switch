import QtQuick
import QtQuick.Shapes
import "IconData.js" as IconData

// A template icon: vector layers tinted with `color`. `size` is the edge of the 16 x 16 design box.
Item {
  id: root
  property string name: ""
  property color color: Theme.label
  property real size: 16
  readonly property var layers: IconData.icons[name] || []
  width: size
  height: size

  Shape {
    width: 16
    height: 16
    scale: root.size / 16
    transformOrigin: Item.TopLeft
    preferredRendererType: Shape.CurveRenderer
    ShapePath {
      id: p0
      readonly property var lay: root.layers[0]
      fillColor: lay && lay.f ? (lay.c || root.color) : "transparent"
      strokeColor: lay && !lay.f ? (lay.c || root.color) : "transparent"
      strokeWidth: lay && !lay.f ? (lay.w || 1.4) : 0
      capStyle: ShapePath.RoundCap
      joinStyle: ShapePath.RoundJoin
      PathSvg { path: p0.lay ? p0.lay.d : "" }
    }
    ShapePath {
      id: p1
      readonly property var lay: root.layers[1]
      fillColor: lay && lay.f ? (lay.c || root.color) : "transparent"
      strokeColor: lay && !lay.f ? (lay.c || root.color) : "transparent"
      strokeWidth: lay && !lay.f ? (lay.w || 1.4) : 0
      capStyle: ShapePath.RoundCap
      joinStyle: ShapePath.RoundJoin
      PathSvg { path: p1.lay ? p1.lay.d : "" }
    }
    ShapePath {
      id: p2
      readonly property var lay: root.layers[2]
      fillColor: lay && lay.f ? (lay.c || root.color) : "transparent"
      strokeColor: lay && !lay.f ? (lay.c || root.color) : "transparent"
      strokeWidth: lay && !lay.f ? (lay.w || 1.4) : 0
      capStyle: ShapePath.RoundCap
      joinStyle: ShapePath.RoundJoin
      PathSvg { path: p2.lay ? p2.lay.d : "" }
    }
    ShapePath {
      id: p3
      readonly property var lay: root.layers[3]
      fillColor: lay && lay.f ? (lay.c || root.color) : "transparent"
      strokeColor: lay && !lay.f ? (lay.c || root.color) : "transparent"
      strokeWidth: lay && !lay.f ? (lay.w || 1.4) : 0
      capStyle: ShapePath.RoundCap
      joinStyle: ShapePath.RoundJoin
      PathSvg { path: p3.lay ? p3.lay.d : "" }
    }
  }
}
