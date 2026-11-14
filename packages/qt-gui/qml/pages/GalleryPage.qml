import QtQuick

// Developer gallery (--gallery only): every design-system control in every state it can show at rest.
// Hover and press are live; keyboard focus is shown with a pinned focus tint.
Item {
  id: page
  property alias header: header
  property alias scroll: scroll

  PageHeader { id: header; width: parent.width }

  component Line: SettingsRow { }

  ScrollArea {
    id: scroll
    anchors.top: header.bottom
    anchors.bottom: parent.bottom
    width: parent.width

    Card {
      title: "Toggles"
      Line { title: "Switch"; help: "off, on, disabled off, disabled on"
        Switch {} Switch { checked: true } Switch { enabled: false } Switch { enabled: false; checked: true } }
      Line { title: "Checkbox"; help: "off, on, mixed, disabled, with label"
        Checkbox {} Checkbox { checked: true } Checkbox { mixed: true } Checkbox { enabled: false; checked: true } Checkbox { text: "Label" } }
      Line { last: true; title: "Chip"; help: "off, on, disabled"
        ChipToggle { text: "Codex" } ChipToggle { text: "Claude"; checked: true } ChipToggle { text: "Droid"; enabled: false } }
    }

    Card {
      title: "Buttons"
      Line { title: "Push button"; help: "normal, prominent, icon, disabled, danger"
        PushButton { text: "Refresh" } PushButton { text: "Sign In"; prominent: true } PushButton { text: "Reveal"; icon: "folder" }
        PushButton { text: "Disabled"; enabled: false } PushButton { text: "Remove…"; textColor: Theme.red } }
      Line { title: "Square and table size"; help: "28 x 28 square, 22 high in table rows"
        PushButton { square: true; icon: "plus"; tip: "Add Account" } PushButton { square: true; icon: "ellipsis"; tip: "More" }
        PushButton { text: "Check"; controlHeight: 22 } }
      Line { title: "Icon button"; help: "normal, danger, active, disabled"
        IconButton { icon: "copy"; tip: "Copy" } IconButton { icon: "xmark"; tone: "danger"; tip: "Remove" }
        IconButton { icon: "eye"; tone: "active"; tip: "Shown" } IconButton { icon: "refresh"; enabled: false; tip: "Refresh" } }
      Line { last: true; title: "Pop-up"; help: "normal, disabled"
        PopUp { options: ["Last place", "Overview"] } PopUp { options: ["1% left", "2% left"]; enabled: false } }
    }

    Card {
      title: "Pickers and fields"
      Line { title: "Segmented"; help: "text, icons"
        Segmented { model: ["System", "Light", "Dark"]; current: 1 } Segmented { model: ["", ""]; icons: ["house", "gearFill"] } }
      Line { title: "Text field"; help: "placeholder, text, secure, disabled"
        FieldBox { width: 140; placeholder: "No message" } FieldBox { width: 140; text: "Continue." }
        FieldBox { width: 100; text: "secret"; secure: true } FieldBox { width: 100; text: "Off"; enabled: false } }
      Line { last: true; title: "Search field"; help: "empty with key hint, with text and clear button"
        SearchField { width: 220 } SearchField { width: 220; text: "codex" } }
    }

    Card {
      title: "Usage and status"
      Line { title: "Usage bar"; help: "62% used, 95% used (red), pace tick, unknown, 0%"
        UsageBar { width: 120; used: 62; provider: "codex"; anchors.verticalCenter: parent.verticalCenter }
        UsageBar { width: 120; used: 95; provider: "claude-code"; anchors.verticalCenter: parent.verticalCenter }
        UsageBar { width: 120; used: 40; pace: 0.5; provider: "droid"; anchors.verticalCenter: parent.verticalCenter }
        UsageBar { width: 120; used: -1; anchors.verticalCenter: parent.verticalCenter }
        UsageBar { width: 120; used: 100; provider: "codex"; anchors.verticalCenter: parent.verticalCenter } }
      Line { title: "Badge and provider marks"; help: "state dots, brand tiles, monogram fallback"
        Badge { text: "Default"; anchors.verticalCenter: parent.verticalCenter }
        Badge { text: "Sign in"; dot: Theme.amber; anchors.verticalCenter: parent.verticalCenter }
        ProviderTile { provider: "codex"; anchors.verticalCenter: parent.verticalCenter }
        ProviderTile { provider: "claude-code"; anchors.verticalCenter: parent.verticalCenter }
        ProviderTile { provider: "droid"; anchors.verticalCenter: parent.verticalCenter }
        ProviderTile { provider: "mistral"; name: "Mistral"; anchors.verticalCenter: parent.verticalCenter } }
      Line { title: "Skeleton"; help: "loading placeholder"
        Skeleton { width: 160; height: 12; anchors.verticalCenter: parent.verticalCenter }
        Skeleton { width: 60; height: 12; anchors.verticalCenter: parent.verticalCenter } }
      Line { last: true; title: "Stat tile"
        StatTile { width: 180; label: "Tokens"; value: "412M"; detail: "In the last 7 days" } }
    }

    Card {
      title: "Surfaces"
      Line { title: "Keyboard focus"; help: "tint in the control's own shape, never a ring"
        Rectangle { width: 80; height: 28; radius: 6; color: Theme.controlFill; border.width: Theme.hair; border.color: Theme.controlBorder
          FocusFill { radius: 6; visible: true } Txt { anchors.centerIn: parent; text: "Focused" } }
        Rectangle { width: 200; height: 32; radius: 8; color: "transparent"
          FocusFill { radius: 8; visible: true } Txt { x: 40; anchors.verticalCenter: parent.verticalCenter; text: "Sidebar row" } } }
      Line { title: "Sidebar rows"; help: "selected, normal"
        Rectangle { width: 200; height: 32; radius: 8; color: Theme.sidebarSelection
          Icon { x: 12.5; anchors.verticalCenter: parent.verticalCenter; name: "gearFill"; size: 15; color: Theme.passiveIcon }
          Txt { x: 40; anchors.verticalCenter: parent.verticalCenter; text: "Settings" } }
        Item { width: 200; height: 32
          Icon { x: 12.5; anchors.verticalCenter: parent.verticalCenter; name: "house"; size: 15; color: Theme.passiveIcon }
          Txt { x: 40; anchors.verticalCenter: parent.verticalCenter; text: "Overview" } } }
      Line { title: "Tooltip"; help: "solid, never see-through"
        Rectangle { width: tipText.implicitWidth + 16; height: tipText.implicitHeight + 6; radius: 5; color: Theme.solidSurface
          border.width: 0.5; border.color: Theme.separator
          Txt { id: tipText; x: 8; y: 3; role: "secondary"; color: Theme.secondary; text: "Clear search" } } }
      Line { last: true; title: "Hairline and type"; help: "Title 17, Section 13 bold, Body 13, Secondary 11, Caption 10"
        Txt { role: "title"; text: "Title" } Txt { role: "section"; text: "Section" } Txt { text: "Body" }
        Txt { role: "secondary"; color: Theme.secondary; text: "Secondary" } Txt { role: "caption"; color: Theme.secondary; text: "Caption" } }
    }
  }
}
