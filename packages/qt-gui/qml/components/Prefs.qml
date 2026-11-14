pragma Singleton
import QtQuick

// The one read and write path for settings (rpc.md Settings). Values come from the helper's `settings`
// topic; a write shows at once and stays pending until the topic carries it. A demo run keeps writes in memory.
QtObject {
  id: prefs
  // Defaults for the keys the app reads, used until the topic arrives (the helper sends effective values).
  readonly property var defaults: ({
    windowAppearance: "system", launchPlace: "last", showEmailDomains: false, hideEmailAddresses: false,
    privacyMode: false, usageTokenPeriod: "yearly", minimizeToTray: false, showAccountUsageInMenuBar: true,
    menuBarTokenPeriod: "sinceReset", menuBarOneAccountPerService: false, showUsageAsUsed: false,
    checkProviderStatus: true, notifyAlmostOut: false, notifyPaceAlerts: false, notifyAvailableAgain: false,
    notifySignInAgain: false, resetTimesExact: false, timeFormat: "auto", refreshWhenMenuOpens: false,
    autoSwitchEnabled: false, autoSwitchThreshold: 1, autoSwitchRunningCLIs: "restart",
    autoSwitchResumeMessage: "Continue. A usage limit cut your last turn short; redo the last step if it did not finish."
  })
  property var pending: ({})
  readonly property var stored: Helper.topics.settings && Helper.topics.settings.values ? Helper.topics.settings.values : ({})
  readonly property bool live: Helper.status !== "demo"

  function same(a, b) { return JSON.stringify(a) === JSON.stringify(b) }
  function value(key) {
    if (key in pending) return pending[key]
    var s = stored[key]
    return s !== undefined && s !== null ? s : defaults[key]
  }
  function drop(key) { var p = Object.assign({}, pending); delete p[key]; pending = p }
  function set(key, v) {
    var p = Object.assign({}, pending); p[key] = v; pending = p
    if (!live) return
    Helper.call("settings.set", { key: key, value: v }, function (result, error) { if (error) prefs.drop(key) })
  }
  function reset() {
    pending = ({})
    if (live) Helper.call("settings.reset", {}, function () {})
  }

  // A pending write ends when the topic shows the same value (the topic may arrive before or after the reply).
  onStoredChanged: {
    var p = {}, changed = false
    for (var k in pending) { if (same(stored[k], pending[k])) changed = true; else p[k] = pending[k] }
    if (changed) pending = p
  }
}
