import SwiftUI
import AIManagerCore

@main
struct AIManagerApp: App {
    @StateObject private var model = AccountViewModel(paths: .environment())

    var body: some Scene {
        WindowGroup("AI Manager") {
            AccountWindow(model: model)
                // The hidden titlebar adds 32 points to the outer frame, keeping its cap at 1240.
                .frame(minWidth: 720, maxWidth: 1840, minHeight: 500, maxHeight: 1208)
                .task { await model.load() }
        }
        .defaultSize(width: 920, height: 620)
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Import Account...") { Task { await model.beginImport() } }
                    .keyboardShortcut("i", modifiers: [.command])
                    .disabled(model.isBusy)
            }
        }
    }
}
