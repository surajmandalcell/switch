import AppKit
import SwiftUI

enum UILintEdge: String { case start, center, end }
enum UILintTag: Hashable {
    case card(radius: CGFloat), tile(radius: CGFloat)
    case control, actions, stack, number
    case align(String, UILintEdge)
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
private let uiLintEnabled = true
#else
private let uiLintEnabled = CommandLine.arguments.contains("--ui-lint")
#endif

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

    func write(to url: URL, size: CGSize, page: String, appearance name: String) throws {
        let document: [String: Any] = ["window": ["width": size.width, "height": size.height,
            "background": color(.windowBackgroundColor)], "appearance": name, "page": page,
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

    func body(content: Content) -> some View {
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
