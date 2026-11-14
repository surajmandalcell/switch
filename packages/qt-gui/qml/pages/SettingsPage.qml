import QtQuick

// Settings page (settings.md 2): every card and row with its spec copy. Values are local until the
// helper's settings topic is wired (settings.get / settings.set); Appearance already drives the theme.
Item {
  id: page
  property alias header: header
  property alias scroll: scroll
  property alias swTray: swTray
  property alias segUsage: segUsage
  property alias versionButton: versionButton
  onVisibleChanged: if (visible) scroll.appear()

  PageHeader { id: header; width: parent.width; placeholder: "Search settings…" }

  ScrollArea {
    id: scroll
    anchors.top: header.bottom
    anchors.bottom: parent.bottom
    width: parent.width
    gutter: 20

    Card {
      title: "General"
      SettingsRow {
        title: "Open at Login"
        help: "Open Switch in the menu bar when you sign in."
        Switch { objectName: "switch-login" }
      }
      SettingsRow {
        title: "Minimize to menu bar"
        help: "Hide the window and keep Switch available from its menu-bar icon."
        Switch { id: swTray }
      }
      SettingsRow {
        title: "When Switch opens"
        help: "Choose the page shown when Switch starts."
        PopUp { options: ["Last place", "Overview"] }
      }
      SettingsRow {
        title: "Menu shortcut"
        help: "Open or close the menu popover from anywhere. Off until you record one."
        PushButton {
          id: rec
          property bool recording: false
          property string combo: ""
          minWidth: 112 + 24   // shell.md 5.1: the text area is at least 112, plus the 12 + 12 padding
          text: recording ? "Press a shortcut…" : (combo !== "" ? combo : "Click to record")
          prominent: recording
          textColor: recording ? "white" : (combo !== "" ? Theme.label : Theme.secondary)
          onClicked: { recording = !recording; if (recording) forceActiveFocus() }
          Keys.onPressed: function (e) {
            if (!recording) return
            e.accepted = true
            if (e.key === Qt.Key_Escape) { recording = false; return }
            var m = e.modifiers
            if (!(m & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))) return
            if (e.key === Qt.Key_Control || e.key === Qt.Key_Alt || e.key === Qt.Key_Meta || e.key === Qt.Key_Shift) return
            combo = ((m & Qt.ControlModifier) ? "⌃" : "") + ((m & Qt.AltModifier) ? "⌥" : "")
                  + ((m & Qt.ShiftModifier) ? "⇧" : "") + ((m & Qt.MetaModifier) ? "⌘" : "") + String.fromCharCode(e.key).toUpperCase()
            recording = false
          }
        }
      }
      SettingsRow {
        last: true
        title: "Version"
        help: "The installed version of Switch."
        Txt { role: "secondary"; color: Theme.secondary; text: Qt.application.version || "Unknown"; anchors.verticalCenter: parent.verticalCenter }
        PushButton { id: versionButton; text: "Update available"; visible: App.flag("update") }
      }
    }

    Card {
      title: "Appearance"
      SettingsRow {
        title: "Appearance"
        help: "Choose the window and menu bar appearance."
        Segmented {
          model: ["System", "Light", "Dark"]
          current: Theme.mode === "system" ? 0 : (Theme.mode === "light" ? 1 : 2)
          onPicked: function (i) { Theme.mode = ["system", "light", "dark"][i] }
        }
      }
      SettingsRow {
        title: "Usage percentage"
        help: "Show the share left or the share used in every usage view."
        Segmented { id: segUsage; model: ["Left", "Used"]; current: Theme.showUsed ? 1 : 0; onPicked: function (i) { Theme.showUsed = i === 1 } }
      }
      SettingsRow {
        title: "Reset times"
        help: "Show a countdown or the exact time. Click any reset text to switch."
        Segmented { model: ["Countdown", "Exact time"] }
      }
      SettingsRow {
        last: true
        title: "Time format"
        help: "Hour style for exact reset times."
        Segmented { model: ["Auto", "12-hour", "24-hour"] }
      }
    }

    Card {
      title: "Accounts"
      SettingsRow { title: "Show full email addresses"; help: "Show the full address, including the domain ending such as .com or .co.uk."; Switch {} }
      SettingsRow { title: "Hide email addresses"; help: "Mask account emails everywhere, such as a••••@example."; Switch {} }
      SettingsRow { title: "Privacy mode"; help: "Show made-up names, such as Jon Doe, instead of account names and emails."; Switch {} }
      SettingsRow { title: "Check provider status"; help: "Show a dot beside a provider that reports an incident."; Switch { checked: true } }
      SettingsRow { last: true; title: "Use the selected Claude account in terminals"; help: "Adds one line to ~/.zshrc so a plain claude command uses the default Claude account. A backup is kept."; Switch {} }
    }

    Card {
      title: "Auto switch"
      SettingsRow { title: "Switch accounts automatically"; help: "Make the next account in your Accounts order the default when one runs out."; Switch { id: auto } }
      SettingsRow { title: "Switch when an account has"; help: "Compares the lower of the session and weekly share left."
        PopUp { enabled: auto.checked; options: ["1% left", "2% left", "5% left", "10% left", "20% left"] } }
      SettingsRow { title: "Running CLIs"; help: "Reopen Codex and Claude Code in Terminal on the new account once their turn ends."
        PopUp { enabled: auto.checked; options: ["Restart when idle", "Leave running"] } }
      SettingsRow { last: true; title: "Resume message"; help: "Sent when a usage limit cut the last turn short."
        FieldBox { width: 320; placeholder: "No message"; opacity: auto.checked ? 1 : 0.45; enabled: auto.checked
          text: "Continue. A usage limit cut your last turn short; redo the last step if it did not finish." } }
    }

    Card {
      title: "Menu bar"
      SettingsRow { title: "Show account usage"; help: "Accounts without their own choice show cached usage in Menubar."; Switch { checked: true } }
      SettingsRow { title: "One account per service"; help: "The menu bar shows the default account of each service, or its first account with usage."; Switch {} }
      SettingsRow { title: "Token summary"; help: "Choose the period shown beside each account’s usage."
        PopUp { options: ["Since reset", "Today", "Yesterday", "Weekly", "Monthly", "Yearly"] } }
      SettingsRow { last: true; title: "Refresh when the menu opens"; help: "Check usage each time the popover opens."; Switch {} }
    }

    Card {
      title: "Notifications"
      SettingsRow { title: "Almost Out"; help: "Alert when a usage window drops below 10% left."; Switch {} }
      SettingsRow { title: "Pace alerts"; help: "Alert when usage will finish close to the limit or run out before the reset."; Switch {} }
      SettingsRow { title: "Available again"; help: "Alert when a used-up window resets and the account can be used again."; Switch {} }
      SettingsRow { last: true; title: "Sign in again"; help: "Alert once when an account needs a new sign-in."; Switch {} }
    }

    Card {
      title: "Data locations"
      Repeater {
        model: [
          { t: "Codex home", h: "Settings, plugins, conversations, and databases stay here when accounts change.", p: "~/.codex" },
          { t: "Codex account vault", h: "Private Codex auth.json snapshots.", p: "/switch/codex-accounts" },
          { t: "Grok Build home", h: "Grok configuration, rules, plugins, sessions, and the active login.", p: "~/.grok" },
          { t: "Grok Build account vault", h: "Private Grok subscription OAuth snapshots.", p: "/switch/grok-accounts" }
        ]
        delegate: SettingsRow {
          last: index === 3
          title: modelData.t
          help: modelData.h
          // shortcut: paths are placeholders under the helper's data location until it reports model.paths
          detail: modelData.p.charAt(0) === "/" ? (Helper.topics.app ? Helper.topics.app.dataLocation : "") + modelData.p : modelData.p
          PushButton { text: "Reveal"; icon: "folder" }
        }
      }
    }

    Card {
      title: "Reset"
      SettingsRow {
        last: true
        title: "Reset settings"
        help: "Return every Settings choice, hidden usage row, and the menu shortcut to its default. Accounts stay."
        PushButton { text: "Reset settings…"; textColor: Theme.red }
      }
    }
  }
}
