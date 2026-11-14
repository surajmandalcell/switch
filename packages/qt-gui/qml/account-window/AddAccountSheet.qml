import QtQuick
import QtQuick.Window
import QtQuick.Dialogs
import "Acc.js" as A

// Add Account and Advanced Import sheets (account-window.md 1.3, 8; accounts.md 5): a 680 x 600 modal
// window over the main window. Title (Title role, 20 padding, 4 below), a scrolling body, a footer with
// the left buttons, the centered "Step N of 3 · Label", Cancel and the default button. An error card
// floats 52 above the bottom edge; while working a spinner and "Checking account…" sit 58 above it.
Window {
  id: sh
  property var ctl
  width: 680
  height: 600
  minimumWidth: 680
  maximumWidth: 680
  minimumHeight: 600
  maximumHeight: 600
  flags: Qt.Dialog | Qt.FramelessWindowHint
  modality: Qt.ApplicationModal
  transientParent: ctl ? ctl.win : null
  color: "transparent"
  title: mode === "import" ? "Import Account" : "Add Account"
  visible: false

  property string mode: "add"          // "add" | "import"
  property int step: 1
  property string kind: ""             // step 2 page: "signin" | "droid" | "secret" | "files"
  property string providerID: ""
  property string boundID: ""          // account-bound sign-in (Sign in again)
  property string doneID: ""           // the saved account on step 3
  property string doneMessage: ""
  property var login: null             // { sessionID, providerID, state, message }
  property string err: ""
  property bool working: false
  property string query: ""
  property string selID: ""
  property var fields: ({})
  // files page: providers.liveIdentity {label, plan}, privacy applied by the helper; undefined while reading
  property var live: undefined
  function readLive() {
    var id = providerID
    live = undefined
    Helper.call("providers.liveIdentity", { providerID: id }, function (r, e) { if (sh.providerID === id) sh.live = e ? null : (r || null) })
  }
  // Advanced Import
  property var sources: []
  property string sourceID: ""
  property int scope: 0                // 0 Account access only (authOnly), 1 Account access, settings, and chats (full)
  property var plan: null
  property var decisions: ({})
  property var result: null

  readonly property string pname: providerID ? ctl.pname(providerID) : ""
  readonly property var catalog: {
    var list = (ctl ? ctl.providers : []).slice(), order = ["codex", "grok-build", "droid", "claude-code"]
    var built = order.map(function (id) { for (var i = 0; i < list.length; ++i) if (list[i].id === id) return list[i]; return null }).filter(function (p) { return !!p })
    var rest = list.filter(function (p) { return order.indexOf(p.id) < 0 })
    rest.sort(function (a, b) { return a.displayName.toLowerCase() < b.displayName.toLowerCase() ? -1 : 1 })
    return built.concat(rest)
  }
  readonly property var shown: catalog.filter(function (p) {
    var words = sh.query.toLowerCase().split(/\s+/).filter(function (w) { return w !== "" })
    var hay = (p.displayName + " " + p.id).toLowerCase()
    return words.every(function (w) { return hay.indexOf(w) >= 0 })
  })
  readonly property var selProvider: { for (var i = 0; i < shown.length; ++i) if (shown[i].id === selID) return shown[i]; return null }
  function usable(p) { return !!p && p.availability !== "disabled" && p.availability !== "unavailable" }

  readonly property string titleText: mode === "import" ? ["Import Account", "Review Import", "Import Result"][step - 1]
      : step === 1 ? "Add Account" : step === 3 ? "Account Ready" : (kind === "secret" ? "Credentials" : "Sign In")
  readonly property string stepText: "Step " + step + " of 3 · " + (mode === "import" ? ["Source", "Review", "Done"][step - 1]
      : ["Provider", kind === "secret" ? "Credentials" : "Sign in", "Done"][step - 1])

  // Menus, tooltips and alerts of the main window cannot draw over this window: borrow them while open.
  property var saved: null
  onVisibleChanged: {
    if (visible) { saved = { m: Theme.menu, t: Theme.tooltip, a: Theme.alert }; Theme.menu = menu; Theme.tooltip = tip; Theme.alert = alert; requestActivate() }
    else if (saved) { Theme.menu = saved.m; Theme.tooltip = saved.t; Theme.alert = saved.a; saved = null }
  }

  function reset() { step = 1; kind = ""; providerID = ""; boundID = ""; doneID = ""; doneMessage = ""; login = null; err = ""; working = false
                     query = ""; fields = ({}); plan = null; decisions = ({}); result = null; sourceID = "" }
  function openAdd() {
    if (ctl.busy) return
    mode = "add"; reset()
    selID = catalog.length ? catalog[0].id : ""
    show()
    search.focusInput()
  }
  function openImport() { if (ctl.busy) return; mode = "import"; reset(); show(); discover() }
  function openSignIn(row) {
    mode = "add"; reset()
    providerID = row.providerID; boundID = row.id; kind = "signin"; step = 2
    show()
    startLogin({ accountID: row.id })
  }
  function dismiss() { if (working) return; if (login) Helper.call("login.cancel", { sessionID: login.sessionID }, function () {}); if (plan) Helper.call("import.discard", { planID: plan.planID }, function () {}); hide() }

  // One request at a time; a needsConfirmation reply asks first and repeats with the token (rpc.md rule 8).
  function call(method, params, failText, done) {
    working = true
    err = ""
    Helper.call(method, params, function (r, e) {
      sh.working = false
      if (e) { if (!(e.data && e.data.kind === "busy")) sh.err = failText(e.message); return }
      if (r && r.status === "needsConfirmation" && r.confirmation) {
        var c = r.confirmation
        alert.open({ title: c.title, message: c.message, action: c.action,
                     onAccept: function () { var p = Object.assign({}, params); p.confirm = c.token; sh.call(method, p, failText, done) } })
        return
      }
      done(r || {})
    })
  }
  function startLogin(params) {
    var name = pname
    call("login.start", params, function (d) { return "Couldn’t start sign-in. " + d + " Confirm that " + name + " is installed, then try again." },
         function (r) { sh.login = r.login || null; sh.kind = "signin"; sh.step = 2; if (sh.login && sh.login.state === "completed") sh.finish(r.accountID || sh.boundID, "") })
  }
  function checkNow(choice) {
    var p = { sessionID: login.sessionID }, name = pname
    if (choice) p.credentialChoice = choice
    if (providerID === "droid") { if (fields.name) p.droidName = String(fields.name).trim(); if (fields.key) p.droidAPIKey = fields.key }
    call("login.check", p, function (d) { return "Couldn’t complete sign-in. " + d + " Finish the " + name + " sign-in and choose Check Now again." },
         function (r) { if (r.login) sh.login = r.login; if (r.login && r.login.state === "completed") sh.finish(r.accountID || sh.boundID, r.login.message || "") })
  }
  function finish(id, message) { login = null; doneID = id || ""; doneMessage = message; step = 3; if (doneID) ctl.select(doneID) }
  function cont() {
    var p = selProvider
    if (!usable(p) || working) return
    providerID = p.id
    if (p.id === "codex" || p.id === "grok-build" || p.id === "claude-code") startLogin({ providerID: p.id })
    else if (p.id === "droid") {
      kind = "droid"; step = 2
      var n = 0
      ctl.allRows.forEach(function (r) { if (r.providerID === "droid") ++n })
      fields = { name: ctl.pref("privacyMode", false) ? "" : "Droid " + (n + 1), key: "" }
    } else { kind = p.fields && p.fields.length ? "secret" : "files"; fields = ({}); step = 2 }
  }
  function back() { err = ""; if (login) { Helper.call("login.cancel", { sessionID: login.sessionID }, function () {}); login = null } if (boundID) { hide(); return } step = 1; kind = "" }
  function save() {
    var name = pname, id = providerID
    if (kind === "secret")
      call("providers.add", { providerID: id, fields: fields }, function (d) { return "Couldn’t save the account. " + d + " Check the credentials and try again." },
           function (r) { sh.finish(r.accountID, name + " account was saved.") })
    else if (kind === "files")
      call("providers.importLive", { providerID: id }, function (d) { return "Couldn’t import the current sign-in. " + d + " Sign in with the official app or CLI, then try again." },
           function (r) { sh.finish(r.accountID, "") })
    else if (kind === "droid") {
      var p = { name: String(fields.name || "").trim() }
      if (fields.key) p.apiKey = fields.key
      call("droid.import", p, function (d) { return "Couldn’t import the Droid account. " + d + " Sign in to Factory, then try again." },
           function (r) { sh.finish(r.accountID, "Droid account saved.") })
    }
  }
  FolderDialog {
    id: folderDialog
    title: "Choose Codex folder"
    onAccepted: sh.discover(decodeURIComponent(String(selectedFolder).replace(/^file:\/\//, "").replace(/^\/([A-Za-z]:)/, "$1")))
  }
  function discover(folder) {
    call("import.discover", folder ? { folder: folder } : {}, function (d) { return d }, function (r) {
      sh.sources = Array.isArray(r) ? r : []
      var ok = sh.sources.filter(function (s) { return s.support === "chatgpt" || s.support === "chatGPTAccount" })
      if (ok.length && sh.sourceID === "") sh.sourceID = ok[0].id
    })
  }
  function review() {
    var src = sources.filter(function (s) { return s.id === sh.sourceID })[0]
    if (!src) return
    call("import.plan", { source: src.path, mode: scope === 1 ? "full" : "authOnly" }, function (d) { return d },
         function (r) { sh.plan = r.plan || r; sh.decisions = ({}); sh.step = 2 })
  }
  function commit() {
    call("import.commit", { planID: plan.planID, decisions: decisions }, function (d) { return d }, function (r) { sh.result = r; sh.plan = null; sh.step = 3 })
  }

  // ---- chrome --------------------------------------------------------------------------------------
  Rectangle {
    anchors.fill: parent
    radius: 10
    color: Theme.page
    border.width: Theme.hair
    border.color: Theme.windowBorder
  }
  Item {
    id: root
    anchors.fill: parent
    focus: true
    Keys.onEscapePressed: sh.dismiss()

    Txt { x: 20; y: 20; role: "title"; text: sh.titleText }

    ScrollArea {
      id: body
      y: 20 + 22 + 4
      width: parent.width
      height: footer.y - y - 8
      gutter: 20
      topPad: 16
      bottomPad: 16
      spacing: 16
      enabled: !sh.working
      Loader {
        width: parent.width
        sourceComponent: sh.mode === "import" ? (sh.step === 1 ? importSource : sh.step === 2 ? importReview : importResult)
                       : sh.step === 1 ? chooser : sh.step === 3 ? donePage
                       : sh.kind === "secret" ? secretPage : sh.kind === "files" ? filesPage : signInPage
      }
    }

    // footer: left buttons, the step text centered over the middle, Cancel + default on the right
    Item {
      id: footer
      x: 20
      y: parent.height - 20 - 28
      width: parent.width - 40
      height: 28
      Txt { anchors.centerIn: parent; role: "secondary"; color: Theme.secondary; text: sh.stepText; Accessible.name: sh.stepText.split(" · ")[0] }
      Row {
        spacing: 8
        PushButton { visible: sh.mode === "add" && sh.step === 1; icon: "folder"; text: "Advanced Import…"; enabled: !sh.working; onClicked: { sh.mode = "import"; sh.reset(); sh.discover() } }
        PushButton { visible: (sh.mode === "add" && sh.step === 2 && sh.kind !== "signin" && !sh.boundID) || (sh.mode === "import" && sh.step === 2)
                     text: "Back"; enabled: !sh.working
                     onClicked: { if (sh.mode === "import") { Helper.call("import.discard", { planID: sh.plan.planID }, function () {}); sh.plan = null; sh.step = 1 } else sh.back() } }
        PushButton { visible: sh.mode === "add" && sh.step === 2 && ((sh.kind === "files" && !!(sh.catalogEntry(sh.providerID) || {}).login) || (sh.kind === "droid" && !sh.login))
                     text: "Sign in another account"; enabled: !sh.working; onClicked: sh.startLogin({ providerID: sh.providerID }) }
        PushButton { visible: sh.step === 3 && (sh.mode === "import" || sh.doneID !== ""); icon: "refresh"; text: "Refresh usage"
                     enabled: !sh.working && sh.ctl.find(sh.doneID) !== null; onClicked: sh.ctl.refresh(sh.ctl.find(sh.doneID)) }
        PushButton { visible: sh.mode === "import" && sh.step === 1; icon: "folder"; text: "Choose Codex folder…"
                     enabled: !sh.working; onClicked: folderDialog.open() }
        IconButton { visible: sh.mode === "import" && sh.step === 1; anchors.verticalCenter: parent.verticalCenter; icon: "refresh"; tip: "Refresh sources"; onClicked: sh.discover() }
      }
      Row {
        anchors.right: parent.right
        spacing: 8
        PushButton { visible: sh.step !== 3; text: "Cancel"; enabled: !sh.working
                     onClicked: (sh.mode === "add" && sh.step === 2 && sh.kind === "signin") ? sh.back() : sh.dismiss() }
        PushButton {
          id: primary
          prominent: true
          text: sh.mode === "import" ? ["Review import", "Import account", "Done"][sh.step - 1]
              : sh.step === 1 ? "Continue" : sh.step === 3 ? "Done"
              : sh.kind === "secret" ? "Save" : sh.kind === "signin" ? "Check Now" : "Import current sign-in"
          icon: sh.mode === "add" && sh.step === 2 && sh.kind === "signin" ? "refresh" : ""
          visible: !(sh.kind === "signin" && sh.login && sh.login.state === "credentialChoiceRequired" && sh.step === 2)
          enabled: !sh.working && (sh.mode === "import" ? (sh.step === 1 ? sh.sourceID !== "" : sh.step === 2 ? sh.conflictsChosen : true)
                 : sh.step === 1 ? sh.usable(sh.selProvider)
                 : sh.step === 3 ? true
                 : sh.kind === "signin" ? !!sh.login
                 : sh.kind === "secret" ? sh.complete
                 : sh.kind === "droid" ? String(sh.fields.name || "").trim() !== ""
                 : sh.kind === "files" ? !!sh.live && !!sh.live.label : true)
          onClicked: sh.primaryAction()
        }
      }
    }
    Keys.onReturnPressed: if (primary.visible && primary.enabled) sh.primaryAction()
    Keys.onUpPressed: sh.moveSel(-1)
    Keys.onDownPressed: sh.moveSel(1)

    // floating error card (52 above the bottom) or the busy line (58 above)
    Rectangle {
      visible: sh.err !== ""
      x: 20
      width: parent.width - 40
      height: Math.max(28, emsg.height) + 16
      y: parent.height - 52 - height
      radius: 10
      color: Theme.card
      border.width: Theme.hair
      border.color: Theme.cardBorder
      Icon { id: ewarn; x: 16; anchors.verticalCenter: parent.verticalCenter; name: "warnFill"; size: 14; color: Theme.red }
      Txt { id: emsg; x: 38; anchors.verticalCenter: parent.verticalCenter; width: ecopy.x - 8 - x; height: implicitHeight
            wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight; text: sh.err }
      AccCopyIcon { id: ecopy; x: edis.x - 12 - width; anchors.verticalCenter: parent.verticalCenter; tip: "Copy error"; onCopy: sh.ctl.copy(sh.err) }
      PushButton { id: edis; x: parent.width - 16 - width; anchors.verticalCenter: parent.verticalCenter; text: "Dismiss"; onClicked: sh.err = "" }
    }
    Row {
      visible: sh.working
      anchors.horizontalCenter: parent.horizontalCenter
      y: parent.height - 58 - 16
      spacing: 8
      AccSpinner { anchors.verticalCenter: parent.verticalCenter }
      Txt { role: "secondary"; color: Theme.secondary; text: sh.mode === "import" ? "Working…" : "Checking account…" }
    }

    Item { id: overlay; anchors.fill: parent }
    MenuPanel { id: menu; parent: overlay }
    Tooltip { id: tip; parent: overlay }
    Alert { id: alert; parent: overlay }
  }

  readonly property bool complete: {
    var p = catalogEntry(providerID)
    if (!p || !p.fields) return false
    return p.fields.every(function (f) { return f.optional || String(sh.fields[f.key] || "").trim() !== "" })
  }
  readonly property bool conflictsChosen: !plan || !plan.conflicts || plan.conflicts.every(function (c) { return sh.decisions[c.relativePath || c.path] !== undefined })
  function catalogEntry(id) { for (var i = 0; i < catalog.length; ++i) if (catalog[i].id === id) return catalog[i]; return null }
  function setField(k, v) { var f = Object.assign({}, fields); f[k] = v; fields = f }
  function moveSel(d) {
    if (mode !== "add" || step !== 1) return
    var ok = shown.filter(usable), i = -1
    for (var k = 0; k < ok.length; ++k) if (ok[k].id === selID) i = k
    i = i < 0 ? (d > 0 ? 0 : ok.length - 1) : Math.max(0, Math.min(ok.length - 1, i + d))
    if (ok.length) selID = ok[i].id
  }
  onShownChanged: if (!selProvider) { var ok = shown.filter(usable); if (ok.length) selID = ok[0].id }
  function primaryAction() {
    if (mode === "import") { if (step === 1) review(); else if (step === 2) commit(); else hide(); return }
    if (step === 1) cont()
    else if (step === 3) hide()
    else if (kind === "signin") checkNow("")
    else save()
  }
  property alias search: searchProxy
  QtObject { id: searchProxy; property var field: null; function focusInput() { if (field) field.focusInput() } }

  // ---- pages ---------------------------------------------------------------------------------------
  component SheetSection: Column {
    property string heading: ""
    width: parent ? parent.width : 400
    spacing: 8
    Txt { visible: parent.heading !== ""; role: "section"; text: parent.heading }
  }
  component Notice: Row {
    property string text: ""
    property bool warn: false
    width: parent ? parent.width : 400
    spacing: 8
    Icon { name: "info"; size: 14; color: parent.warn ? Theme.amber : Theme.accent }
    Txt { width: parent.width - 22; text: parent.text; wrapMode: Text.Wrap; height: implicitHeight }
  }

  Component {
    id: chooser
    Column {
      spacing: 12
      SearchField {
        id: sf
        width: parent.width
        placeholder: "Search providers"
        hint: ""
        text: sh.query
        onTextChanged: sh.query = text
        Component.onCompleted: { searchProxy.field = sf; sf.focusInput() }
      }
      Rectangle {
        width: parent.width
        height: Math.max(36, list.height)
        radius: 10
        color: "transparent"
        clip: true
        Column {
          id: list
          width: parent.width
          spacing: 2
          Repeater {
            model: sh.shown
            delegate: Item {
              readonly property bool ok: sh.usable(modelData)
              readonly property bool picked: sh.selID === modelData.id
              readonly property bool signedIn: modelData.signedIn === true
              width: list.width
              height: 20 + 16 + 2
              opacity: ok ? 1 : 0.64
              Rectangle { anchors.fill: parent; radius: 6; color: parent.picked ? Theme.rowHighlight : (rowHover.hovered && parent.ok ? Theme.rowHover : "transparent") }
              HoverHandler { id: rowHover }
              ProviderTile { x: 8; anchors.verticalCenter: parent.verticalCenter; size: 20; provider: modelData.id; name: modelData.displayName }
              Column {
                x: 36
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - 36 - 8 - badges.width - 8
                Txt { text: modelData.displayName; width: parent.width; elide: Text.ElideRight }
                Txt { id: subt; visible: text !== ""; role: "secondary"; color: Theme.secondary; width: parent.width; elide: Text.ElideRight
                      text: sh.subtitle(modelData); ToolTipArea { text: subt.truncated ? subt.text : "" } }
              }
              Row {
                id: badges
                anchors.right: parent.right
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                spacing: 6
                Badge { visible: parent.parent.signedIn; text: "Signed in on this Mac"; dot: Theme.green }
                Badge { visible: !parent.parent.ok; text: "WIP"; dot: Theme.secondary }
              }
              MouseArea {
                anchors.fill: parent
                enabled: parent.ok
                onClicked: { sh.selID = modelData.id; if (searchProxy.field) searchProxy.field.focusInput() }
                onDoubleClicked: { sh.selID = modelData.id; sh.cont() }
              }
            }
          }
          Txt { visible: sh.shown.length === 0; x: 8; height: 36; role: "secondary"; color: Theme.secondary; text: "No provider matches “" + sh.query + "”." }
        }
      }
    }
  }
  function subtitle(p) {
    if (!usable(p)) return p.unavailableReason || "Account setup is not available in this version."
    if (p.id === "codex") return "Account switching and usage are supported."
    if (A.isBuiltIn(p.id)) return "Subscription account switching is supported."
    if (p.style === "files") return p.login ? "Saves the sign-in of the official app or CLI." : "Saves the sign-in of the official app."
    if (p.style === "secret") {
      var need = (p.fields || []).filter(function (f) { return !f.optional }).map(function (f) { return f.title })
      return need.length ? "Needs: " + need.join(", ") + "." : "Saves a credential."
    }
    return ""   // providers.list carries no style yet (helper need)
  }

  Component {
    id: signInPage
    SheetSection {
      heading: sh.pname + " sign-in"
      spacing: 16
      Column {
        visible: sh.providerID === "droid"
        width: parent.width
        spacing: 8
        FieldBox { width: parent.width; placeholder: "Account name"; enabled: !sh.boundID; Component.onCompleted: text = sh.fields.name || ""; onTextChanged: sh.setField("name", text)
                   Accessible.description: "Name this encrypted login, for example Droid personal." }
        FieldBox { visible: !sh.login && !sh.boundID; width: parent.width; secure: true; placeholder: "Factory API key (optional, for usage)"
                   onTextChanged: sh.setField("key", text) }
        Txt { role: "secondary"; color: Theme.secondary; width: parent.width; wrapMode: Text.Wrap; height: implicitHeight
              text: "Switch saves the encrypted login and checks Droid's masked email. Equal masks can belong to different people. Type /login in Terminal when adding another account." }
      }
      Row {
        width: parent.width
        spacing: 10
        Icon { name: sh.login && sh.login.state === "needsAttention" ? "warnFill" : "people"; size: 16
               color: sh.login && sh.login.state === "needsAttention" ? Theme.amber : Theme.accent }
        Column {
          width: parent.width - 26
          spacing: 2
          Txt { role: "section"; text: "Finish signing in to " + sh.pname }
          Txt { role: "secondary"; color: Theme.secondary; width: parent.width; wrapMode: Text.Wrap; height: implicitHeight
                text: "Sign in through a private temporary home. The saved account becomes available to " + sh.pname + " after you finish." }
        }
      }
      Column {
        visible: sh.providerID === "grok-build" && !!sh.login
        width: parent.width
        spacing: 8
        FieldBox { id: code; width: parent.width; secure: true; placeholder: "Paste from the Grok browser page"
                   Accessible.name: "Authorization code or callback URL"; Keys.onReturnPressed: if (submit.enabled) submit.clicked() }
        Item {
          width: parent.width
          height: 28
          Txt { anchors.verticalCenter: parent.verticalCenter; role: "secondary"; color: Theme.secondary; text: "Switch sends this once to the waiting Grok CLI and does not save it." }
          PushButton {
            id: submit
            anchors.right: parent.right
            text: "Submit Code"
            enabled: !sh.working && code.text.trim() !== ""
            onClicked: sh.call("login.submitCode", { sessionID: sh.login.sessionID, code: code.text.trim() },
                               function (d) { return "Couldn’t submit the Grok authorization code. " + d + " Start Grok sign-in again if the code expired." },
                               function () { code.text = "" })
          }
        }
      }
      Notice {
        warn: !!sh.login && sh.login.state === "needsAttention"
        text: sh.login && sh.login.message ? sh.login.message : "Finish signing in to " + sh.pname + ", then return here and choose Check Now."
      }
      Column {
        visible: !!sh.login && sh.login.state === "credentialChoiceRequired"
        width: parent.width
        spacing: 8
        Txt { text: "This account is already saved with different access." }
        Row {
          spacing: 8
          PushButton { text: "Use new sign-in"; prominent: true; enabled: !sh.working; onClicked: sh.checkNow("useNew") }
          PushButton { text: "Keep saved access"; enabled: !sh.working; onClicked: sh.checkNow("keepSaved") }
        }
      }
      Txt {
        visible: !(sh.login && sh.login.state === "credentialChoiceRequired")
        role: "secondary"; color: Theme.secondary
        text: A.isBuiltIn(sh.providerID) ? "When the browser reports success, return to Switch and check the account."
                                         : "When the sign-in finishes in Terminal, return to Switch and check the account."
      }
    }
  }

  Component {
    id: secretPage
    SheetSection {
      heading: sh.pname + " credentials"
      spacing: 16
      readonly property var spec: sh.catalogEntry(sh.providerID) || ({ fields: [] })
      Row {
        spacing: 10
        ProviderTile { size: 32; provider: sh.providerID; name: sh.pname; anchors.verticalCenter: parent.verticalCenter }
        Column {
          anchors.verticalCenter: parent.verticalCenter
          Txt { role: "section"; text: "Add a " + sh.pname + " account" }
          Txt { role: "secondary"; color: Theme.secondary; text: "Switch keeps these values in a private file on this Mac and uses them only to read usage." }
        }
      }
      Repeater {
        model: parent.spec.fields || []
        delegate: Column {
          width: parent.width
          spacing: 4
          Txt { text: modelData.title }
          FieldBox { width: parent.width; secure: !!modelData.secure
                     placeholder: modelData.placeholder || (modelData.secure ? "Paste the " + modelData.title.toLowerCase() : "")
                     Accessible.name: modelData.title + (modelData.optional ? ", optional" : "")
                     onTextChanged: sh.setField(modelData.key, text); Keys.onReturnPressed: if (sh.complete) sh.save() }
          Txt { visible: !!modelData.optional; role: "secondary"; color: Theme.secondary; text: "Optional" }
        }
      }
    }
  }

  Component {
    id: filesPage
    SheetSection {
      id: files
      heading: sh.pname + " sign-in"
      spacing: 16
      readonly property var live: sh.live
      readonly property bool reading: live === undefined
      readonly property bool found: !!live && !!live.label
      readonly property bool hasLogin: !!(sh.catalogEntry(sh.providerID) || {}).login
      Component.onCompleted: sh.readLive()
      Row {
        spacing: 10
        ProviderTile { size: 32; provider: sh.providerID; name: sh.pname; anchors.verticalCenter: parent.verticalCenter }
        Column {
          anchors.verticalCenter: parent.verticalCenter
          Txt { role: "section"; text: files.reading ? "Looking for a sign-in…" : files.found ? "Signed in as " + files.live.label : "No sign-in found" }
          Txt {
            role: "secondary"; color: Theme.secondary
            text: files.reading ? "Reading the current sign-in without changing it."
                : files.found && files.live.plan ? "Plan: " + String(files.live.plan).charAt(0).toUpperCase() + String(files.live.plan).slice(1)
                : files.found ? "This is the sign-in that " + sh.pname + " holds on this computer right now."
                : "Sign in with the official " + sh.pname + " app or CLI first, then import it here."
          }
        }
      }
      // shortcut: no "Read from <first credential file>" row; providers.list has no credential paths yet
      Notice {
        visible: !files.reading
        warn: !files.found
        text: files.found ? (files.hasLogin ? "Import saves this sign-in. Sign in another account opens Terminal for a second login."
                                            : "Import saves this sign-in so Switch can switch back to it later.")
                          : (files.hasLogin ? "Sign in with " + sh.pname + ", or choose Sign in another account to do it from Switch."
                                            : "Sign in with the official app, then return here.")
      }
    }
  }

  Component {
    id: donePage
    SheetSection {
      heading: "Ready"
      spacing: 12
      readonly property var row: sh.ctl.find(sh.doneID)
      Row {
        spacing: 8
        Icon { name: "checkCircle"; size: 16; color: Theme.green; anchors.verticalCenter: parent.verticalCenter }
        Txt { role: "section"; text: parent.parent.row ? parent.parent.row.label : sh.pname + " account" }
      }
      Txt { role: "secondary"; color: Theme.secondary; text: sh.doneMessage || "The account is saved and ready to use." }
      Txt {
        role: "secondary"; color: Theme.secondary; width: parent.width; wrapMode: Text.Wrap; height: implicitHeight
        text: sh.providerID === "codex" ? "The account is ready for new Codex sessions. Shared settings and chats stay in place."
            : sh.providerID === "claude-code" ? "The account is ready in its own Claude Code profile. Your usual Claude session stays in place."
            : sh.providerID === "grok-build" ? "The account is ready in Grok Build. Its settings and sessions stay in the shared Grok home."
            : "The account is saved. Its usage appears in Switch, and Set as Default makes it the one that " + sh.pname + " uses."
      }
      Row {
        spacing: 8
        PushButton { visible: !!parent.parent.row; text: parent.parent.row && parent.parent.row.isDefault ? "Using as default" : "Make Default"
                     enabled: !!parent.parent.row && !parent.parent.row.isDefault && !sh.ctl.busy; onClicked: sh.ctl.switchDefault(parent.parent.row) }
        PushButton { visible: A.isBuiltIn(sh.providerID) && !!parent.parent.row; icon: "play"; text: "Open " + A.toolName(sh.providerID, sh.ctl.names)
                     onClicked: sh.ctl.openAccount(parent.parent.row) }
      }
    }
  }

  Component {
    id: importSource
    Column {
      spacing: 16
      SheetSection {
        Txt { text: "Choose a provider and one of its data folders." }
        PopUp { options: ["Codex CLI"]; name: "Provider" }
      }
      SheetSection {
        heading: "Source"
        Txt { visible: sh.sources.length === 0; role: "secondary"; color: Theme.secondary; text: "No Codex accounts found. Refresh or choose another folder." }
        Repeater {
          model: sh.sources
          delegate: Item {
            readonly property bool ok: modelData.support === "chatgpt" || modelData.support === "chatGPTAccount"
            readonly property string supportText: ({ chatgpt: "ChatGPT account", chatGPTAccount: "ChatGPT account", subscriptionOAuth: "Subscription OAuth",
                                                     apiKey: "API key", missingAuth: "Missing auth", malformedAuth: "Malformed auth",
                                                     keychainOnly: "Keychain only" })[modelData.support] || "Unknown format"
            width: parent.width
            height: srcCol.height + 16
            opacity: ok ? 1 : 0.58
            Rectangle { anchors.fill: parent; radius: 6; color: sh.sourceID === modelData.id ? Theme.rowHighlight : "transparent" }
            Icon { x: 8; y: 10; name: "check"; size: 12; color: Theme.accent; visible: sh.sourceID === modelData.id }
            Column {
              id: srcCol
              x: 28
              y: 8
              width: parent.width - 28 - 8 - sup.width - 8
              Txt { text: modelData.identity && modelData.identity.email ? modelData.identity.email : modelData.path.split("/").pop() }
              AccFact { ctl: sh.ctl; label: ""; value: modelData.path }
              Txt { role: "secondary"; tabular: true; color: Theme.secondary
                    text: (modelData.settings ? modelData.settings.length : 0) + " settings · " + (modelData.history ? modelData.history.activeTranscripts : 0)
                          + " active · " + (modelData.history ? modelData.history.archivedTranscripts : 0) + " archived" }
              Txt { visible: !!modelData.inspectionError; role: "secondary"; color: Theme.amber; width: parent.width; wrapMode: Text.Wrap
                    maximumLineCount: 2; height: implicitHeight; text: modelData.inspectionError || "" }
            }
            Badge { id: sup; anchors.right: parent.right; anchors.rightMargin: 8; y: 10; text: parent.supportText; dot: parent.ok ? Theme.green : Theme.amber }
            MouseArea { anchors.fill: parent; enabled: parent.ok; onClicked: sh.sourceID = modelData.id }
          }
        }
      }
      SheetSection {
        heading: "Import scope"
        PopUp { options: ["Account access only", "Account access, settings, and chats"]; name: "Import scope"; current: sh.scope; onPicked: function (i) { sh.scope = i } }
        Txt { role: "secondary"; color: Theme.secondary; width: parent.width; wrapMode: Text.Wrap; height: implicitHeight
              text: sh.scope === 1 ? "Reviews Codex-home conflicts and adds source chats to the merged library. Everything affected is backed up first."
                                   : "Saves account access. Settings and chats stay in the current Codex home. The source stays unchanged." }
      }
    }
  }

  Component {
    id: importReview
    Column {
      spacing: 16
      readonly property var p: sh.plan || ({})
      SheetSection {
        heading: "Plan"
        AccFact { ctl: sh.ctl; label: "Account"; value: parent.parent.p.label || "" }
        AccFact { ctl: sh.ctl; label: "Source"; value: parent.parent.p.source || "" }
        AccFact { ctl: sh.ctl; label: "Space needed"; value: sh.bytes(parent.parent.p.requiredBytes || 0) }
      }
      SheetSection {
        visible: (parent.p.warnings || []).length > 0
        heading: "Warnings"
        Txt { role: "secondary"; color: Theme.secondary; text: A.plural((parent.parent.p.warnings || []).length, "item needs attention", "items need attention") }
        Repeater { model: parent.parent.p.warnings || []
                   delegate: Row { spacing: 8; Icon { name: "warnFill"; size: 13; color: Theme.amber } Txt { text: typeof modelData === "string" ? modelData : (modelData.message || "") } } }
      }
      SheetSection {
        visible: (parent.p.conflicts || []).length > 0
        heading: "Conflicts"
        Repeater {
          model: parent.parent.p.conflicts || []
          delegate: Item {
            readonly property string key: modelData.relativePath || modelData.path
            width: parent.width
            height: 28
            AccFact { ctl: sh.ctl; width: parent.width - seg.width - 16; anchors.verticalCenter: parent.verticalCenter; label: ""; value: parent.key }
            Segmented { id: seg; anchors.right: parent.right; model: ["Keep shared", "Use imported"]
                        current: sh.decisions[parent.key] === "useImported" ? 1 : (sh.decisions[parent.key] === "keepShared" ? 0 : -1)
                        onPicked: function (i) { var d = Object.assign({}, sh.decisions); d[parent.key] = i === 1 ? "useImported" : "keepShared"; sh.decisions = d } }
          }
        }
      }
      SheetSection {
        heading: "Manifest · " + ((parent.p.files || []).length) + " selected"
        Repeater { model: (parent.parent.p.files || []).slice(0, 200)
                   delegate: AccFact { ctl: sh.ctl; label: ""; value: typeof modelData === "string" ? modelData : (modelData.path || modelData.relativePath || "") } }
      }
    }
  }

  Component {
    id: importResult
    SheetSection {
      heading: "Import complete"
      Row { spacing: 8; Icon { name: "checkCircle"; size: 16; color: Theme.green } Txt { text: sh.result && sh.result.notice ? sh.result.notice : "" } }
      Notice { text: "The imported account is ready. Choose Use for new Codex sessions when you want to switch." }
    }
  }

  function bytes(n) {
    var u = ["bytes", "KB", "MB", "GB", "TB"], i = 0
    while (n >= 1000 && i < u.length - 1) { n /= 1000; ++i }
    return (i === 0 ? n : n.toFixed(n < 10 ? 1 : 0)) + " " + u[i]
  }
}
