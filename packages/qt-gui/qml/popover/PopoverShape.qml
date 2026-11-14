import QtQuick
import QtQuick.Shapes

// The popover outline as one closed path with circular corners (the Mac popover's corner profile fits a
// circle of radius 16 within 1 px on every row). The arrow's shoulders leave the edge tangentially and meet at a rounded
// tip: each side is one cubic with horizontal tangents at both ends. The bake-off drew straight lines,
// which met the edge at a hard angle. Drawn for an arrow on top; arrowDown mirrors it vertically.
Item {
  id: s
  property real arrowX: width / 2      // tip x in this item
  property bool arrowDown: false
  property bool arrow: true
  property color fill: Theme.popoverFill
  property color stroke: Theme.popoverBorder
  property real strokeWidth: Theme.hair
  readonly property real a: arrow ? Theme.arrowHeight : 0
  readonly property real r: Theme.popoverRadius
  readonly property real span: r
  readonly property real hw: Theme.arrowWidth / 2
  readonly property real ax: Math.max(span + hw, Math.min(width - span - hw, arrowX))
  // Shoulder control (along the edge) and tip control (along the tip tangent), in px from the ends.
  readonly property real shoulder: 6.5
  readonly property real tip: 2.6

  // One corner at C, clockwise; q points from C to where the corner ends.
  function corner(cx, cy, qx, qy) { return " A" + r + " " + r + " 0 0 1 " + (cx + qx * r) + " " + (cy + qy * r) }
  readonly property string outline: {
    var w = width, h = height, e = span
    return "M" + e + " " + a
      + " L" + (ax - hw) + " " + a
      + " C" + (ax - hw + shoulder) + " " + a + " " + (ax - tip) + " 0 " + ax + " 0"
      + " C" + (ax + tip) + " 0 " + (ax + hw - shoulder) + " " + a + " " + (ax + hw) + " " + a
      + " L" + (w - e) + " " + a + corner(w, a, 0, 1)
      + " L" + w + " " + (h - e) + corner(w, h, -1, 0)
      + " L" + e + " " + h + corner(0, h, 0, -1)
      + " L0 " + (a + e) + corner(0, a, 1, 0) + " Z"
  }

  Shape {
    anchors.fill: parent
    preferredRendererType: Shape.CurveRenderer
    transform: Scale { origin.y: s.height / 2; yScale: s.arrowDown ? -1 : 1 }
    ShapePath {
      fillColor: s.fill
      strokeColor: s.stroke
      strokeWidth: s.strokeWidth
      joinStyle: ShapePath.RoundJoin
      PathSvg { path: s.outline }
    }
  }
}
