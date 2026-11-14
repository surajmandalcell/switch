import QtQuick
import QtQuick.Dialogs

// The folder picker of maintenance.md 9: folders only, one selection, title and button from the caller.
// Loaded by URL so a system without QtQuick.Dialogs only loses this dialog, not the page.
FolderDialog {
  property var done: null
  acceptLabel: "Choose"
  onAccepted: if (done) done(decodeURIComponent(String(selectedFolder).replace(/^file:\/\//, "")))
}
