import SwiftUI
import AIManagerCore

@main
struct AIManagerApp: App {
    @StateObject private var model = AccountViewModel(paths: .environment())

    var body: some Scene {
        WindowGroup("AI Manager") {
            AccountWindow(model: model)
                .frame(minWidth: 720, minHeight: 500)
                .task { await model.load() }
        }
        .defaultSize(width: 920, height: 620)
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
