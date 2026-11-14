import QtQuick

// A Card that fades in (opacity 0.4 to 1, 0.25 s ease-out) each time it appears and never moves
// (maintenance.md 1.4 "Fade-in rule"). A titled card gets the hairline under its title, as AIMSection does.
Card {
  id: mc
  divider: title !== ""
  onVisibleChanged: if (visible) fade.restart()
  Component.onCompleted: if (visible) fade.restart()
  NumberAnimation { id: fade; target: mc; property: "opacity"; from: 0.4; to: 1; duration: Theme.dAppear
                    easing.type: Easing.Bezier; easing.bezierCurve: Theme.easeOut }
}
