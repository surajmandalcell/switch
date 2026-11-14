import QtQuick
import "Acc.js" as A

// "Account details" (account-window.md 2.7). Built-ins: Saved auth (Claude Code: Profile config), Source,
// <Provider> home, Imported, Last used. Generic: Saved sign-in, Imported, Last switched.
Card {
  id: card
  property var ctl
  property var row
  readonly property var acc: ctl.statusOf(row.id) || ({})
  readonly property bool builtIn: A.isBuiltIn(row.providerID)
  readonly property string homePath: row.providerID === "claude-code" ? (acc.home || "") : (ctl.homes[row.providerID] || acc.home || "")
  readonly property var facts: builtIn ? [
      { l: row.providerID === "claude-code" ? "Profile config" : "Saved auth", v: acc.credentialFile || "" },
      { l: "Source", v: acc.source || "" },
      { l: ctl.pname(row.providerID) + " home", v: homePath },
      { l: "Imported", v: A.dateTime(acc.importedAt, ctl.h24) },
      { l: "Last used", v: acc.lastUsedAt ? A.dateTime(acc.lastUsedAt, ctl.h24) : "Not launched yet" }
    ] : [
      { l: "Saved sign-in", v: acc.credentialFile || "" },
      { l: "Imported", v: A.dateTime(acc.importedAt, ctl.h24) },
      { l: "Last switched", v: acc.lastUsedAt ? A.dateTime(acc.lastUsedAt, ctl.h24) : "Not switched yet" }
    ]
  title: "Account details"

  Repeater {
    model: card.facts
    delegate: AccSecRow {
      last: index === card.facts.length - 1
      AccFact { ctl: card.ctl; label: modelData.l; value: modelData.v }
    }
  }
}
