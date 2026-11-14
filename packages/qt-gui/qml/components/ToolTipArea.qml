import QtQuick

// Attach to a control to show its tooltip (4.18) after the usual OS delay. Never moves layout.
HoverHandler {
  id: h
  property string text: ""
  property int delay: 700
  enabled: text !== ""
  onHoveredChanged: {
    if (hovered) timer.restart()
    else { timer.stop(); if (Theme.tooltip) Theme.tooltip.hide(h.parent) }
  }
  property Timer timer: Timer { interval: h.delay; onTriggered: if (Theme.tooltip) Theme.tooltip.show(h.parent, h.text) }
}
