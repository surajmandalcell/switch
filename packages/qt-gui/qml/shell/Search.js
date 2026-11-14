.pragma library
// Global search logic (shell.md 4.1). ENTRIES is the local copy of the Settings index (4.4); the shell swaps
// in the helper's app.searchIndex when the helper has it, so the copy only serves older helpers and demo runs.

var ENTRIES = [
  ["login", "General", "Open at Login", "Open Switch in the menu bar when you sign in.", "startup launch boot login item"],
  ["tray", "General", "Minimize to menu bar", "Hide the window and keep Switch available from its menu-bar icon.", "tray dock hide"],
  ["place", "General", "When Switch opens", "Choose the page shown when Switch starts.", "startup launch home last page"],
  ["shortcut", "General", "Menu shortcut", "Open or close the menu popover from anywhere. Off until you record one.", "hotkey keyboard key global"],
  ["version", "General", "Version", "The installed version of Switch.", "update upgrade release build about"],
  ["appearance", "Appearance", "Appearance", "Choose the window and menu bar appearance.", "theme dark light mode system"],
  ["percent", "Appearance", "Usage percentage", "Show the share left or the share used in every usage view.", "left used percent remaining"],
  ["reset-times", "Appearance", "Reset times", "Show a countdown or the exact time. Click any reset text to switch.", "countdown exact clock"],
  ["hours", "Appearance", "Time format", "Hour style for exact reset times.", "12 24 hour clock"],
  ["domain", "Accounts", "Show full email addresses", "Show the full address, including the domain ending such as .com or .co.uk.", "privacy mask hide"],
  ["hide-email", "Accounts", "Hide email addresses", "Mask account emails everywhere, such as a••••@example.", "privacy mask hide"],
  ["privacy", "Accounts", "Privacy mode", "Show made-up names, such as Jon Doe, instead of account names and emails.", "privacy mask hide fake screenshot"],
  ["status", "Accounts", "Check provider status", "Show a dot beside a provider that reports an incident.", "incident outage"],
  ["claude-shell", "Accounts", "Use the selected Claude account in terminals", "Adds one line to ~/.zshrc so a plain claude command uses the default Claude account. A backup is kept.", "terminal zsh shell"],
  ["auto", "Auto switch", "Switch accounts automatically", "Make the next account in your Accounts order the default when one runs out.", "automatic rotate limit"],
  ["auto-threshold", "Auto switch", "Switch when an account has", "Compares the lower of the session and weekly share left.", "automatic rotate limit percent"],
  ["auto-clis", "Auto switch", "Running CLIs", "Reopen Codex and Claude Code in Terminal on the new account once their turn ends.", "automatic rotate limit terminal restart"],
  ["auto-resume", "Auto switch", "Resume message", "Sent when a usage limit cut the last turn short.", "automatic rotate limit message prompt"],
  ["menu-usage", "Menu bar", "Show account usage", "Accounts without their own choice show cached usage in Menubar.", "menubar popover"],
  ["menu-one-per-service", "Menu bar", "One account per service", "The menu bar shows the default account of each service, or its first account with usage.", "menubar tray single default account service provider"],
  ["menu-tokens", "Menu bar", "Token summary", "Choose the period shown beside each account’s usage.", "menubar popover period"],
  ["menu-refresh", "Menu bar", "Refresh when the menu opens", "Check usage each time the popover opens.", "menubar popover update"],
  ["notify.notifyAlmostOut", "Notifications", "Almost Out", "Alert when a usage window drops below 10% left.", "alert notify notification banner"],
  ["notify.notifyPaceAlerts", "Notifications", "Pace alerts", "Alert when usage will finish close to the limit or run out before the reset.", "alert notify notification banner"],
  ["notify.notifyAvailableAgain", "Notifications", "Available again", "Alert when a used-up window resets and the account can be used again.", "alert notify notification banner"],
  ["notify.notifySignInAgain", "Notifications", "Sign in again", "Alert once when an account needs a new sign-in.", "alert notify notification banner"],
  ["data.codex", "Data locations", "Codex home", "Settings, plugins, conversations, and databases stay here when accounts change.", "folder path vault finder reveal"],
  ["data.codex-vault", "Data locations", "Codex account vault", "Private Codex auth.json snapshots.", "folder path vault finder reveal"],
  ["data.grok", "Data locations", "Grok Build home", "Grok configuration, rules, plugins, sessions, and the active login.", "folder path vault finder reveal"],
  ["data.grok-vault", "Data locations", "Grok Build account vault", "Private Grok subscription OAuth snapshots.", "folder path vault finder reveal"],
  ["reset", "Reset", "Reset settings", "Return every Settings choice, hidden usage row, and the menu shortcut to its default. Accounts stay.", "default restore"]
].map(function (e) { return { id: e[0], section: e[1], title: e[2], help: e[3], keywords: e[4] } })

// Case and accent folding: "Café" and "cafe" match.
function fold(s) { return String(s || "").normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase() }
function terms(q) { return fold(q).split(/\s+/).filter(function (t) { return t !== "" }) }
function blank(q) { return terms(q).length === 0 }

// Every term in section, title, help, or keywords; rank 0 title starts with the query, 1 every term in the
// title, 2 the rest; ties keep the index order.
function settings(query, entries) {
  var ts = terms(query)
  if (ts.length === 0) return entries.slice()
  var whole = ts.join(" "), ranked = []
  for (var i = 0; i < entries.length; ++i) {
    var e = entries[i], hay = fold([e.section, e.title, e.help, e.keywords].join(" "))
    if (!ts.every(function (t) { return hay.indexOf(t) >= 0 })) continue
    var title = fold(e.title)
    var rank = title.indexOf(whole) === 0 ? 0 : (ts.every(function (t) { return title.indexOf(t) >= 0 }) ? 1 : 2)
    ranked.push({ rank: rank, index: i, entry: e })
  }
  ranked.sort(function (a, b) { return a.rank - b.rank || a.index - b.index })
  return ranked.map(function (r) { return r.entry })
}

// shortcut: the accounts topic carries the shown label, id, and provider only; email, user id, and workspace
// id join the match once the topic has them.
function accounts(query, rows, names) {
  var ts = terms(query)
  if (ts.length === 0) return []
  return (rows || []).filter(function (r) {
    var hay = fold([r.label, r.id, names[r.providerID] || r.providerID].join(" "))
    return ts.every(function (t) { return hay.indexOf(t) >= 0 })
  })
}

function count(n) { return n + (n === 1 ? " match" : " matches") }
