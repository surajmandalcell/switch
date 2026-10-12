import AppKit
import SwiftUI

#if UI_LINT_SELF_CHECK
// The standalone geometry fixture does not load the app's design components.
enum AIMTextRole { case title, section, body, secondary, caption }
#endif

// This harness uses the same recorder as the window, with no ordered-in window.
private struct LintCard: View {
    let bad: Bool
    var body: some View {
        VStack(spacing: 16) {
            row.padding(.horizontal, 16)
            row.padding(.horizontal, bad ? 10 : 16)
        }
        .padding(.vertical, 16)
        .frame(width: 320)
        .uiLint(.card(radius: 10), fill: Color(nsColor: .controlBackgroundColor))
    }
    private var row: some View {
        HStack {
            Text("Name").uiLint(.align("name", .start))
            Spacer()
            Text("Value").uiLint(.align("value", .end))
        }
    }
}

@main enum UILintSelfCheck {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for bad in [true, false] {
            UILintStore.shared.items.removeAll()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 180),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .aqua)
            UILintStore.shared.appearance = window.effectiveAppearance
            let view = NSHostingView(rootView: LintCard(bad: bad).frame(maxWidth: .infinity, maxHeight: .infinity))
            window.contentView = view
            window.orderOut(nil)
            let deadline = Date().addingTimeInterval(0.5)
            repeat {
                view.layoutSubtreeIfNeeded()
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            } while Date() < deadline
            precondition(!UILintStore.shared.items.isEmpty, "Offscreen layout did not record frames")
            for group in ["name", "value"] {
                let positions = UILintStore.shared.items.values.compactMap { item -> Double? in
                    guard let tags = item["tags"] as? [[String: Any]],
                          tags.contains(where: { $0["group"] as? String == group }),
                          let frame = item["frame"] as? [String: CGFloat] else { return nil }
                    return Double(frame["x"]! + (group == "value" ? frame["width"]! : 0))
                }
                precondition(positions.count == 2 && abs(abs(positions[0] - positions[1]) - (bad ? 6 : 0)) < 0.1,
                    "Measured column edges must differ by 6 points for BAD and 0 for GOOD")
            }
            try UILintStore.shared.write(to: directory.appendingPathComponent(bad ? "BAD.json" : "GOOD.json"),
                size: view.bounds.size, page: bad ? "BAD" : "GOOD", appearance: "light")
            window.contentView = nil
        }
    }
}
