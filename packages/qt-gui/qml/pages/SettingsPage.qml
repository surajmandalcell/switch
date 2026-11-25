import QtQuick
import QtQuick.Window
import QtQuick.Effects

// Settings page (settings.md 2): every card and row with its spec copy. Each row reads and writes one key
// through Prefs (the helper's settings topic); Open at Login and the menu shortcut belong to the platform.
Item {
  id: page
  property alias header: header
  property alias scroll: scroll
  property alias swTray: swTray
  property alias segUsage: segUsage
  property alias versionButton: versionButton
  readonly property bool autoOn: Prefs.value("autoSwitchEnabled") === true
  onVisibleChanged: if (visible) scroll.appear(); else rec.recording = false

  // Search (shell.md 4.1): a row shows when its index id matches; a card shows when one of its rows does.
  readonly property var win: Window.window
  readonly property bool searching: !!win && !win.searchBlank
  readonly property var hits: { var m = {}; if (win) win.settingsHits.forEach(function (e) { m[e.id] = true }); return m }
  readonly property var hitAccounts: searching ? win.accountHits : []
  // --script states --page Settings: the Accounts card (claude-shell and Terminal app rows)
  function captureSteps(d) {
    return [function () { scroll.scrollTo(accountsCard.y) }, 400, function () { d.shot(Window.window, "settings-accounts") },
            function () { scroll.scrollTo(aboutCard.y - 120) }, 400, function () { d.shot(Window.window, "settings-about") },
            function () { scroll.scrollTo(1e6) }, 400, function () { d.shot(Window.window, "settings-end") },
            // Add Account morph: Accounts draws it wide; back on Settings it is square again
            function () { Window.window.show(1) }, 600, function () { d.shot(Window.window, "accounts-add-wide") },
            function () { Window.window.show(2) }, 600, function () { d.shot(Window.window, "settings-add-square") }]
  }
  function shows(id) { return !searching || hits[id] === true }
  function anyShows(ids) { return ids.some(shows) }
  // (an inline component cannot see this file's ids, so it reads the window's search state itself)
  component SRow: SettingsRow {
    property string sid
    property var group: []
    readonly property var w: Window.window
    function on(id) { return !w || w.searchBlank || w.settingsHits.some(function (e) { return e.id === id }) }
    visible: on(sid)
    last: { for (var i = group.length - 1; i >= 0; --i) if (on(group[i])) return group[i] === sid; return false }
  }
  readonly property var gGeneral: ["login", "tray", "place", "shortcut", "version"]
  readonly property var gAppearance: ["appearance", "percent", "reset-times", "hours"]
  readonly property var gAccounts: ["domain", "hide-email", "privacy", "status", "claude-shell", "terminal"]
  readonly property var gAuto: ["auto", "auto-threshold", "auto-clis", "auto-resume"]
  readonly property var gMenu: ["menu-usage", "menu-one-per-service", "menu-tokens", "menu-refresh"]
  readonly property var gNotify: ["notify.notifyAlmostOut", "notify.notifyPaceAlerts", "notify.notifyAvailableAgain", "notify.notifySignInAgain"]
  readonly property var gData: ["data.codex", "data.codex-vault", "data.grok", "data.grok-vault"]

  // A control keeps its binding to the stored value: a pick writes the key, then binds again (the
  // pending write already shows, so nothing flickers).
  component PrefSwitch: Switch {
    property string key
    objectName: "pref-" + key
    checked: Prefs.value(key) === true
    onToggled: function (v) { Prefs.set(key, v); checked = Qt.binding(function () { return Prefs.value(key) === true }) }
  }
  component PrefSegmented: Segmented {
    property string key
    property var values: []
    objectName: "pref-" + key
    current: Math.max(0, values.indexOf(Prefs.value(key)))
    onPicked: function (i) { Prefs.set(key, values[i]); current = Qt.binding(function () { return Math.max(0, values.indexOf(Prefs.value(key))) }) }
  }
  component PrefPopUp: PopUp {
    property string key
    property var values: []
    objectName: "pref-" + key
    current: Math.max(0, values.indexOf(Prefs.value(key)))
    onPicked: function (i) { Prefs.set(key, values[i]); current = Qt.binding(function () { return Math.max(0, values.indexOf(Prefs.value(key))) }) }
  }

  readonly property string repo: "https://github.com/samhqapp/switch"
  // Settings > About link rows: the label left, the link title and an up-right arrow right (Mac AboutLinkRow).
  component LinkRow: SettingsRow {
    id: lr
    property string url
    property string linkTitle
    AboutLink { text: lr.linkTitle; url: lr.url; anchors.verticalCenter: parent.verticalCenter }
  }
  component AboutLink: Item {
    id: ln
    property string text
    property string url
    implicitWidth: lnRow.width
    implicitHeight: 20
    width: implicitWidth
    height: implicitHeight
    activeFocusOnTab: true
    Accessible.role: Accessible.Link
    Accessible.name: text
    Accessible.onPressAction: Qt.openUrlExternally(url)
    Keys.onSpacePressed: Qt.openUrlExternally(url)
    Keys.onReturnPressed: Qt.openUrlExternally(url)
    FocusFill { anchors.margins: -2; radius: 4; visible: ln.activeFocus && App.keyboardMode }
    Row {
      id: lnRow
      spacing: 4
      anchors.verticalCenter: parent.verticalCenter
      Txt { role: "secondary"; color: Theme.secondary; text: ln.text; anchors.verticalCenter: parent.verticalCenter }
      Icon { name: "arrowUpRight"; size: 9; color: Theme.tertiary; anchors.verticalCenter: parent.verticalCenter }
    }
    ToolTipArea { text: ln.url }
    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: Qt.openUrlExternally(ln.url) }
  }

  PageHeader { id: header; width: parent.width; placeholder: "Search settings…" }

  ScrollArea {
    id: scroll
    anchors.top: header.bottom
    anchors.bottom: parent.bottom
    width: parent.width
    gutter: 20

    Card {
      title: "General"
      visible: page.anyShows(page.gGeneral)
      SRow {
        sid: "login"; group: page.gGeneral
        title: "Open at Login"
        // settings.md 6.1 help lines; Linux and Windows have no approval or not-found state (shell.md 6.4)
        help: App.loginError !== "" ? "Switch couldn’t update its login item: " + App.loginError
              : (App.loginEnabled ? "Switch opens in the " + Theme.trayName + " when you sign in."
                                  : "Open Switch in the " + Theme.trayName + " when you sign in.")
        Switch {
          objectName: "switch-login"
          checked: App.loginEnabled
          onToggled: function (v) { App.loginEnabled = v; checked = Qt.binding(function () { return App.loginEnabled }) }
        }
      }
      SRow {
        sid: "tray"; group: page.gGeneral
        title: "Minimize to " + Theme.trayName
        help: "Hide the window and keep Switch available from its " + Theme.trayName + " icon."
        PrefSwitch { id: swTray; key: "minimizeToTray" }
      }
      SRow {
        sid: "place"; group: page.gGeneral
        title: "When Switch opens"
        help: "Choose the page shown when Switch starts."
        PrefPopUp { key: "launchPlace"; values: ["last", "overview"]; options: ["Last place", "Overview"] }
      }
      SRow {
        sid: "shortcut"; group: page.gGeneral
        title: "Menu shortcut"
        // shell.md 5.2: without the GlobalShortcuts portal or an X11 display (or off Linux) the row is off
        help: App.globalShortcuts ? "Open or close the menu popover from anywhere. Off until you record one."
                                  : "Global shortcuts need a supported desktop"
        Txt { visible: rec.hint !== ""; text: rec.hint; role: "secondary"; color: Theme.amber; anchors.verticalCenter: parent.verticalCenter }
        PushButton {
          id: rec
          // settings.md 2.1: { keyCode: Mac virtual key, modifiers: the Carbon mask (Command 256, Shift 512, Option 2048,
          // Control 4096) }; an unknown key code loads as none.
          readonly property var combo: { var c = Prefs.value("globalShortcut"); return c && typeof c.keyCode === "number" && App.qtKey(c.keyCode) ? c : null }
          property bool recording: false
          property string hint: ""
          enabled: App.globalShortcuts
          minWidth: 112 + 24   // shell.md 5.1: the text area is at least 112, plus the 12 + 12 padding
          text: recording ? "Press a shortcut…" : (combo ? page.comboText(combo) : "Click to record")
          prominent: recording
          textColor: recording ? "white" : (combo ? Theme.label : Theme.secondary)
          Accessible.name: "Global shortcut"
          Accessible.description: "Records a shortcut that opens the menu popover from anywhere"
          onClicked: { recording = !recording; hint = ""; if (recording) forceActiveFocus() }
          // shell.md 5.1 Refused, reworded for Linux; Main.qml clears the stored combo.
          Connections { target: App; function onShortcutRefused() {
            rec.hint = Qt.platform.os === "windows" ? "Windows or another app already uses this shortcut."
                                                    : "The desktop or another app already uses this shortcut." } }
          Keys.onPressed: function (e) {
            if (!recording) return
            e.accepted = true
            if (e.key === Qt.Key_Escape) { recording = false; return }
            if (e.key === Qt.Key_Backspace || e.key === Qt.Key_Delete) { Prefs.set("globalShortcut", null); recording = false; return }
            if (e.key === Qt.Key_Control || e.key === Qt.Key_Alt || e.key === Qt.Key_Meta || e.key === Qt.Key_Shift || e.key === Qt.Key_Super_L) return
            var m = e.modifiers
            if (!(m & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))) { hint = "Include Ctrl, Alt, or " + page.superName + "."; return }
            var code = App.macKeyCode(e.key)
            if (code < 0) return   // a key the Mac format cannot store (media keys and similar): keep recording
            Prefs.set("globalShortcut", { keyCode: code, modifiers: ((m & Qt.MetaModifier) ? 256 : 0) | ((m & Qt.ShiftModifier) ? 512 : 0)
                                                                 | ((m & Qt.AltModifier) ? 2048 : 0) | ((m & Qt.ControlModifier) ? 4096 : 0) })
            hint = ""
            recording = false
          }
        }
        IconButton { anchors.verticalCenter: parent.verticalCenter; visible: !!rec.combo && rec.enabled; icon: "xmarkCircle"; glyph: 13; tip: "Clear global shortcut"; onClicked: Prefs.set("globalShortcut", null) }
      }
      SRow {
        sid: "version"; group: page.gGeneral
        title: "Version"
        help: "The installed version of Switch."
        Txt { role: "secondary"; color: Theme.secondary; anchors.verticalCenter: parent.verticalCenter
              text: (Helper.server && Helper.server.serverVersion) || Qt.application.version || "Unknown" }
        // The update check is Mac-only; --update draws the button only to compare with the Mac capture.
        PushButton { id: versionButton; text: "Update available"; visible: App.flag("update") }
      }
    }

    Card {
      title: "Appearance"
      visible: page.anyShows(page.gAppearance)
      SRow {
        sid: "appearance"; group: page.gAppearance
        title: "Appearance"
        help: "Choose the window and " + Theme.trayName + " appearance."
        PrefSegmented { key: "windowAppearance"; values: ["system", "light", "dark"]; model: ["System", "Light", "Dark"] }
      }
      SRow {
        sid: "percent"; group: page.gAppearance
        title: "Usage percentage"
        help: "Show the share left or the share used in every usage view."
        PrefSegmented { id: segUsage; key: "showUsageAsUsed"; values: [false, true]; model: ["Left", "Used"] }
      }
      SRow {
        sid: "reset-times"; group: page.gAppearance
        title: "Reset times"
        help: "Show a countdown or the exact time. Click any reset text to switch."
        PrefSegmented { key: "resetTimesExact"; values: [false, true]; model: ["Countdown", "Exact time"] }
      }
      SRow {
        sid: "hours"; group: page.gAppearance
        title: "Time format"
        help: "Hour style for exact reset times."
        PrefSegmented { key: "timeFormat"; values: ["auto", "12h", "24h"]; model: ["Auto", "12-hour", "24-hour"] }
      }
    }

    Card {
      id: accountsCard
      title: "Accounts"
      visible: page.anyShows(page.gAccounts)
      SRow { sid: "domain"; group: page.gAccounts; title: "Show full email addresses"; help: "Show the full address, including the domain ending such as .com or .co.uk."; PrefSwitch { key: "showEmailDomains" } }
      SRow { sid: "hide-email"; group: page.gAccounts; title: "Hide email addresses"; help: "Mask account emails everywhere, such as a••••@example."; PrefSwitch { key: "hideEmailAddresses" } }
      SRow { sid: "privacy"; group: page.gAccounts; title: "Privacy mode"; help: "Show made-up names, such as Jon Doe, instead of account names and emails."; PrefSwitch { key: "privacyMode" } }
      SRow { sid: "status"; group: page.gAccounts; title: "Check provider status"; help: "Show a dot beside a provider that reports an incident."; PrefSwitch { key: "checkProviderStatus" } }
      // settings.md claude-shell: the switch shows the marked line's presence; a toggle sets it, then re-reads it.
      // On failure a red line under the help says "Couldn’t update the shell setup. <error>".
      SRow { sid: "claude-shell"; group: page.gAccounts; title: "Use the selected Claude account in terminals"
        help: shellLine.supported ? "Adds one line to ~/.zshrc so a plain claude command uses the default Claude account. A backup is kept."
                                  : "Not available on Windows yet. PowerShell and Command Prompt don’t read ~/.zshrc."
        error: shellLine.error
        Switch {
          id: shellLine
          objectName: "pref-claudeShell"
          property string error: ""
          property bool supported: true   // claude.shellIntegration.get says false on Windows
          enabled: supported && Helper.hasMethod("claude.shellIntegration.set")
          function read() {
            if (Helper.hasMethod("claude.shellIntegration.get"))
              Helper.call("claude.shellIntegration.get", {}, function (r, err) {
                if (err) return
                shellLine.supported = r.shellIntegrationSupported !== false
                shellLine.checked = r.enabled === true
              })
          }
          Component.onCompleted: read()
          onToggled: function (on) {
            error = ""
            Helper.call("claude.shellIntegration.set", { enabled: on }, function (r, err) {
              if (err) shellLine.error = "Couldn’t update the shell setup. " + (err.message || "")
              shellLine.read()
            })
          }
        } }
      // rpc.md Settings: Linux and Windows add terminalEmulator, a program name or path ("" = the first one found)
      SRow { sid: "terminal"; group: page.gAccounts; title: "Terminal app"; help: "Opens sign-ins and tools. Empty uses the first one found."
        FieldBox {
          id: term
          objectName: "pref-terminalEmulator"
          width: 220
          placeholder: "First one found"
          text: Prefs.value("terminalEmulator") || ""
          Connections {
            target: term.input
            function onEditingFinished() {
              if (term.text === (Prefs.value("terminalEmulator") || "")) return
              Prefs.set("terminalEmulator", term.text.trim())
              term.text = Qt.binding(function () { return Prefs.value("terminalEmulator") || "" })
            }
          }
        } }
    }

    Card {
      title: "Auto switch"
      visible: page.anyShows(page.gAuto)
      SRow { sid: "auto"; group: page.gAuto; title: "Switch accounts automatically"; help: "Make the next account in your Accounts order the default when one runs out."; PrefSwitch { key: "autoSwitchEnabled" } }
      SRow { sid: "auto-threshold"; group: page.gAuto; title: "Switch when an account has"; help: "Compares the lower of the session and weekly share left."
        PrefPopUp { enabled: page.autoOn; key: "autoSwitchThreshold"; values: [1, 2, 5, 10, 20]; options: ["1% left", "2% left", "5% left", "10% left", "20% left"] } }
      SRow { sid: "auto-clis"; group: page.gAuto; title: "Running CLIs"; help: "Reopen Codex and Claude Code in Terminal on the new account once their turn ends."
        PrefPopUp { enabled: page.autoOn; key: "autoSwitchRunningCLIs"; values: ["restart", "leave"]; options: ["Restart when idle", "Leave running"] } }
      SRow { sid: "auto-resume"; group: page.gAuto; title: "Resume message"; help: "Sent when a usage limit cut the last turn short."
        FieldBox {
          id: resume
          width: 320
          placeholder: "No message"
          enabled: page.autoOn
          opacity: enabled ? 1 : 0.45
          text: Prefs.value("autoSwitchResumeMessage")
          // write on Return or focus loss, not per key: one settings.set per edit
          Connections {
            target: resume.input
            function onEditingFinished() {
              if (resume.text === Prefs.value("autoSwitchResumeMessage")) return
              Prefs.set("autoSwitchResumeMessage", resume.text)
              resume.text = Qt.binding(function () { return Prefs.value("autoSwitchResumeMessage") })
            }
          }
        }
      }
    }

    Card {
      title: Theme.trayTitle
      visible: page.anyShows(page.gMenu)
      SRow { sid: "menu-usage"; group: page.gMenu; title: "Show account usage"; help: "Accounts without their own choice show cached usage in the " + Theme.trayName + "."; PrefSwitch { key: "showAccountUsageInMenuBar" } }
      SRow { sid: "menu-one-per-service"; group: page.gMenu; title: "One account per service"; help: "The " + Theme.trayName + " shows the default account of each service, or its first account with usage."; PrefSwitch { key: "menuBarOneAccountPerService" } }
      SRow { sid: "menu-tokens"; group: page.gMenu; title: "Token summary"; help: "Choose the period shown beside each account’s usage."
        PrefPopUp { key: "menuBarTokenPeriod"; values: ["sinceReset", "today", "yesterday", "weekly", "monthly", "yearly"]
                    options: ["Since reset", "Today", "Yesterday", "Weekly", "Monthly", "Yearly"] } }
      SRow { sid: "menu-refresh"; group: page.gMenu; title: "Refresh when the menu opens"; help: "Check usage each time the popover opens."; PrefSwitch { key: "refreshWhenMenuOpens" } }
    }

    Card {
      title: "Notifications"
      visible: page.anyShows(page.gNotify)
      SRow { sid: "notify.notifyAlmostOut"; group: page.gNotify; title: "Almost Out"; help: "Alert when a usage window drops below 10% left."; PrefSwitch { key: "notifyAlmostOut" } }
      SRow { sid: "notify.notifyPaceAlerts"; group: page.gNotify; title: "Pace alerts"; help: "Alert when usage will finish close to the limit or run out before the reset."; PrefSwitch { key: "notifyPaceAlerts" } }
      SRow { sid: "notify.notifyAvailableAgain"; group: page.gNotify; title: "Available again"; help: "Alert when a used-up window resets and the account can be used again."; PrefSwitch { key: "notifyAvailableAgain" } }
      SRow { sid: "notify.notifySignInAgain"; group: page.gNotify; title: "Sign in again"; help: "Alert once when an account needs a new sign-in."; PrefSwitch { key: "notifySignInAgain" } }
    }

    Card {
      title: "Data locations"
      visible: page.anyShows(page.gData)
      Repeater {
        id: locations
        // the helper's app.dataLocations; the demo (no helper) shows the documented defaults
        readonly property string store: App.homePath + "/.local/share/switch"
        model: Helper.topics.app && Helper.topics.app.dataLocations ? Helper.topics.app.dataLocations : [
          { title: "Codex home", detail: "Settings, plugins, conversations, and databases stay here when accounts change.", path: App.homePath + "/.codex" },
          { title: "Codex account vault", detail: "Private Codex auth.json snapshots.", path: store + "/codex-accounts" },
          { title: "Grok Build home", detail: "Grok configuration, rules, plugins, sessions, and the active login.", path: App.homePath + "/.grok" },
          { title: "Grok Build account vault", detail: "Private Grok subscription OAuth snapshots.", path: store + "/grok-accounts" }
        ]
        delegate: SRow {
          id: loc
          sid: page.gData[index]; group: page.gData
          title: modelData.title
          help: modelData.detail
          detail: modelData.path
          PushButton { text: "Reveal"; icon: "folder"; Accessible.name: "Reveal " + loc.title; onClicked: App.reveal(loc.detail) }
        }
      }
    }

    Card {
      title: "Reset"
      visible: page.shows("reset")
      SRow {
        sid: "reset"; group: ["reset"]
        title: "Reset settings"
        help: "Return every Settings choice, hidden usage row, and the menu shortcut to its default. Accounts stay."
        PushButton {
          objectName: "reset-settings"
          text: "Reset settings…"
          textColor: Theme.red
          onClicked: Theme.alert.open({ title: "Reset every setting to its default?", message: "Accounts, saved sign-ins, and Open at Login stay as they are.",
                                        action: "Reset settings", destructive: true, onAccept: function () { rec.recording = false; Prefs.reset() } })
        }
      }
    }

    // Settings > About (Mac SwitchAboutSettings): a titled hero card, Links, Credits, then the copyright.
    // Not in the search index, so it hides while a search runs. The About window and its Animation card are Mac only.
    Card {
      id: aboutCard
      objectName: "about-card"
      title: "About"
      visible: !page.searching
      Column {
        width: parent.width
        topPadding: 16
        bottomPadding: 16
        Image {
          anchors.horizontalCenter: parent.horizontalCenter
          source: "assets/appicon.png"; width: 84; height: 84; sourceSize: Qt.size(168, 168)
          Accessible.ignored: true
          layer.enabled: true
          layer.effect: MultiEffect { shadowEnabled: true; shadowColor: "black"; shadowOpacity: 0.18; shadowBlur: 0.4; shadowVerticalOffset: 4 }
        }
        Item { width: 1; height: 10 }
        Txt { anchors.horizontalCenter: parent.horizontalCenter; role: "title"; text: "Switch" }
        Item { width: 1; height: 3 }
        Txt { anchors.horizontalCenter: parent.horizontalCenter; role: "secondary"; color: Theme.secondary
              text: "Coding accounts and usage. Right in your " + (Theme.trayName || "tray") + "." }
        Item { width: 1; height: 6 }
        Txt { anchors.horizontalCenter: parent.horizontalCenter; role: "secondary"; color: Theme.secondary
              text: "Version " + ((Helper.server && Helper.server.serverVersion) || Qt.application.version || "unknown") }
        Item { width: 1; height: 14 }
        PushButton { anchors.horizontalCenter: parent.horizontalCenter; text: "What's New"; onClicked: Qt.openUrlExternally(page.repo + "/releases") }
      }
    }
    readonly property var aboutLinks: [
      { label: "Website", title: "switch.samhq.app", url: "https://switch.samhq.app" },
      { label: "Release notes", title: "GitHub releases", url: page.repo + "/releases" },
      { label: "Report a problem", title: "GitHub issues", url: page.repo + "/issues" },
      { label: "License", title: "MIT license", url: page.repo + "/blob/master/LICENSE" }
    ]
    readonly property var aboutCredits: [
      { label: "OpenUsage", title: "Usage adapters", url: "https://github.com/robinebers/openusage" },
      { label: "CodexBar", title: "Usage adapters", url: "https://github.com/steipete/CodexBar" }
    ]
    Card {
      title: "Links"
      visible: !page.searching
      Repeater {
        model: scroll.aboutLinks
        LinkRow { title: modelData.label; linkTitle: modelData.title; url: modelData.url; last: index === scroll.aboutLinks.length - 1 }
      }
    }
    Card {
      title: "Credits"
      visible: !page.searching
      Repeater {
        model: scroll.aboutCredits
        LinkRow { title: modelData.label; linkTitle: modelData.title; url: modelData.url; last: index === scroll.aboutCredits.length - 1 }
      }
    }
    Item {
      visible: !page.searching
      width: parent.width
      height: 16
      Txt { anchors.horizontalCenter: parent.horizontalCenter; role: "secondary"; color: Theme.secondary; text: "© 2026 Suraj Mandal" }
    }

    // shell.md 4.1 end cards, only while fewer than 3 settings match
    readonly property bool few: page.searching && page.win.settingsHits.length < 3
    Card {
      visible: scroll.few && page.win.settingsHits.length === 0 && page.hitAccounts.length > 0
      Txt { x: 16; height: 44; color: Theme.secondary; text: "No settings match “" + (page.win ? page.win.searchQuery.trim() : "") + "”." }
    }
    MatchCard {
      visible: scroll.few && page.hitAccounts.length > 0
      rows: page.hitAccounts
      names: page.win ? page.win.providerNames : ({})
      onPicked: function (r) { page.win.pickAccount(r.id) }
    }
    Card {
      visible: scroll.few && page.win.settingsHits.length === 0 && page.hitAccounts.length === 0
      Column {
        width: parent.width
        topPadding: 24
        bottomPadding: 24
        spacing: 6
        Icon { anchors.horizontalCenter: parent.horizontalCenter; name: "search"; size: 13; color: Theme.secondary }
        Txt { anchors.horizontalCenter: parent.horizontalCenter; role: "section"; text: "No results for “" + (page.win ? page.win.searchQuery.trim() : "") + "”" }
        Txt { anchors.horizontalCenter: parent.horizontalCenter; role: "secondary"; color: Theme.secondary; text: "Try a setting such as Appearance, or an account name." }
      }
    }
  }

  // settings.md 8.4: the Command-equivalent key is the Windows key on Windows and Super on Linux.
  readonly property string superName: Qt.platform.os === "windows" ? "Win" : "Super"
  // shell.md 5.1 on Linux and Windows: the shortcut as text, modifiers in the Mac order (Control, Option, Shift, Command).
  function comboText(c) {
    var m = c.modifiers || 0, key = App.qtKey(c.keyCode), names = { 16777220: "Return", 16777217: "Tab", 32: "Space", 16777219: "Backspace", 16777216: "Esc",
      16777234: "Left", 16777236: "Right", 16777235: "Up", 16777237: "Down", 16777232: "Home", 16777233: "End",
      16777238: "Page Up", 16777239: "Page Down", 16777223: "Delete" }
    var k = key >= 16777264 && key <= 16777283 ? "F" + (key - 16777263) : (names[key] || (key > 0 && key < 0x110000 ? String.fromCharCode(key).toUpperCase() : "Key " + c.keyCode))
    return ((m & 4096) ? "Ctrl+" : "") + ((m & 2048) ? "Alt+" : "") + ((m & 512) ? "Shift+" : "") + ((m & 256) ? page.superName + "+" : "") + k
  }
}
