import AppKit
import SwiftUI

enum UILintEdge: String { case start, center, end }
enum UILintTag: Hashable {
    case card(radius: CGFloat), tile(radius: CGFloat)
    case control, actions, stack, number
    /// Visible content such as an icon or a bar, for the card padding check.
    case item
    /// A card whose content scrolls to its edges, so the padding check skips it.
    case scrolls
    case align(String, UILintEdge)
}

private struct UILintSuppressedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// Off-screen measuring hosts set this so their layout never reaches the lint export.
    var uiLintSuppressed: Bool {
        get { self[UILintSuppressedKey.self] }
        set { self[UILintSuppressedKey.self] = newValue }
    }
}

extension View {
    @ViewBuilder func uiLint(_ tags: UILintTag..., fill: Color? = nil,
                             file: StaticString = #fileID, line: UInt = #line) -> some View {
        #if AI_MANAGER_PREVIEW
        if uiLintEnabled {
            modifier(UILintRecorder(tags: tags, fill: fill, source: "\(file):\(line)"))
        } else { self }
        #else
        self
        #endif
    }

    @ViewBuilder func uiLintText(_ role: AIMTextRole, monospaced: Bool = false, tint: Color? = nil,
                                 file: StaticString = #fileID, line: UInt = #line) -> some View {
        #if AI_MANAGER_PREVIEW
        if uiLintEnabled {
            modifier(UILintRecorder(tags: [], fill: nil, source: "\(file):\(line)", role: role,
                                    monospaced: monospaced, tint: tint))
        } else { self }
        #else
        self
        #endif
    }
}

#if AI_MANAGER_PREVIEW
// Contract previews keep their normal layout cost; only lint exports attach geometry readers.
#if UI_LINT_SELF_CHECK
private var uiLintEnabled = true
#else
private var uiLintEnabled = CommandLine.arguments.contains("--ui-lint")
#endif
/// A contract check turns recording on while it hosts a view, to measure frames, then off again.
@discardableResult func uiLintRecording(_ on: Bool) -> Bool {
    defer { uiLintEnabled = on }
    return uiLintEnabled
}

@MainActor final class UILintStore {
    static let shared = UILintStore()
    var items: [UUID: [String: Any]] = [:]
    var colors: [UUID: (fill: NSColor?, text: NSColor?)] = [:]
    var appearance = NSAppearance(named: .aqua)!

    func color(_ color: NSColor) -> String {
        var result = "#00000000"
        appearance.performAsCurrentDrawingAppearance {
            if let rgb = color.usingColorSpace(.sRGB) {
                result = String(format: "#%02x%02x%02x%02x", Int((rgb.redComponent * 255).rounded()),
                    Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()),
                    Int((rgb.alphaComponent * 255).rounded()))
            }
        }
        return result
    }

    func write(to url: URL, size: CGSize, page: String, appearance name: String,
               background: NSColor = .windowBackgroundColor) throws {
        let document: [String: Any] = ["window": ["width": size.width, "height": size.height,
            "background": color(background)], "appearance": name, "page": page,
            "items": items.sorted { $0.key.uuidString < $1.key.uuidString }.map { id, value in
                var item = value
                if let fill = colors[id]?.fill { item["fill"] = color(fill) }
                if let text = colors[id]?.text { item["color"] = color(text) }
                return item
            }]
        try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
            .write(to: url)
    }
}

private struct UILintRecorder: ViewModifier {
    let tags: [UILintTag]
    let fill: Color?
    let source: String
    var role: AIMTextRole? = nil
    var monospaced = false
    var tint: Color? = nil
    @State private var id = UUID()
    @Environment(\.uiLintSuppressed) private var suppressed

    func body(content: Content) -> some View {
        if suppressed { content } else { recorded(content) }
    }

    private func recorded(_ content: Content) -> some View {
        content.background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { record(geometry.frame(in: .global)) }
                    .onChange(of: geometry.frame(in: .global)) { _, frame in record(frame) }
                    .onDisappear {
                        UILintStore.shared.items.removeValue(forKey: id)
                        UILintStore.shared.colors.removeValue(forKey: id)
                    }
            }
        }
    }

    @MainActor private func record(_ frame: CGRect) {
        let store = UILintStore.shared
        var names: [[String: Any]] = []
        var item: [String: Any] = ["kind": role == nil ? "view" : "text", "source": source,
            "frame": ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height]]
        for tag in tags {
            switch tag {
            case .card(let radius): names.append(["name": "card"]); item["radius"] = radius
            case .tile(let radius): names.append(["name": "tile"]); item["radius"] = radius
            case .control: names.append(["name": "control"]); item["kind"] = "control"
            case .actions: names.append(["name": "actions"])
            case .stack: names.append(["name": "stack"])
            case .number: names.append(["name": "number"])
            case .item: names.append(["name": "item"])
            case .scrolls: names.append(["name": "scrolls"])
            case .align(let group, let edge): names.append(["name": "align", "group": group, "edge": edge.rawValue])
            }
        }
        item["tags"] = names
        store.colors[id] = (fill.map(NSColor.init), role.map { role in
            tint.map(NSColor.init) ?? (role == .secondary ? .secondaryLabelColor : .labelColor)
        })
        if let fill { item["fill"] = store.color(NSColor(fill)) }
        if let role {
            let style: NSFont.TextStyle = switch role {
            case .title: .title2
            case .section: .headline
            case .body: .body
            case .secondary: .subheadline
            case .caption: .caption1
            }
            let font = NSFont.preferredFont(forTextStyle: style)
            item["fontSize"] = font.pointSize
            item["fontWeight"] = role == .section ? 700 : (role == .title ? 600 : 400)
            item["fontFamily"] = monospaced ? "SF Mono" : "SF Pro"
            item["color"] = store.color(tint.map(NSColor.init) ?? (role == .secondary ? .secondaryLabelColor : .labelColor))
        }
        store.items[id] = item
    }
}
#endif
