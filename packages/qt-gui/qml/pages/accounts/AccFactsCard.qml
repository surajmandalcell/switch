import QtQuick

// "Usage facts" (accounts.md 2.10, Codex): label-left, value-right rows; tooltip "<label>: <value>" (+ ". <help>").
Card {
  id: card
  property var facts: []
  title: "Usage facts"
  Repeater {
    model: card.facts
    delegate: AccSecRow {
      last: index === card.facts.length - 1
      AccFact { width: parent.width; label: modelData.label; value: modelData.value
                tip: modelData.label + ": " + modelData.value + (modelData.help ? ". " + modelData.help : "") }
    }
  }
}
