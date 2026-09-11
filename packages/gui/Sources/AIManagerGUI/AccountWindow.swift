import AppKit
import SwiftUI
import AIManagerCore

private enum UI {
    static let surface = Color(nsColor: .controlBackgroundColor).opacity(0.72)
    static let canvasFallback = Color(nsColor: .windowBackgroundColor)
    static let sidebarFallback = Color(nsColor: .underPageBackgroundColor)
    static let muted = Color(nsColor: .secondaryLabelColor)
    static let blue = Color(nsColor: .systemBlue)
    static let teal = Color(nsColor: .systemTeal)
    static let orange = Color(nsColor: .systemOrange)
    static let red = Color(nsColor: .systemRed)
    static let radius: CGFloat = 3
    static let hoverDuration = 0.15
}

private struct MaterialPane: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

private struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { configure(view.window) }
    }

    private func configure(_ window: NSWindow?) {
        window?.isOpaque = false
        window?.backgroundColor = .clear
        window?.styleMask.insert(.fullSizeContentView)
        window?.titlebarAppearsTransparent = true
        window?.titleVisibility = .hidden
        window?.isMovableByWindowBackground = true
    }
}

private struct ProductiveButtonBody<Label: View>: View {
    let label: Label
    let kind: ProductiveButton.Kind
    let pressed: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        label
            .font(.system(.body, weight: .medium))
            .foregroundStyle(kind == .secondary ? Color.primary : Color.white)
            .padding(.horizontal, 14)
            .frame(minHeight: 34)
            .background(fill.opacity(pressed ? 0.76 : (hovering ? 0.88 : 1)), in: RoundedRectangle(cornerRadius: UI.radius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: UI.radius, style: .continuous))
            .opacity(isEnabled ? 1 : 0.42)
            .onHover { value in
                withAnimation(reduceMotion ? nil : .easeOut(duration: UI.hoverDuration)) { hovering = value }
            }
    }

    private var fill: Color {
        switch kind {
        case .primary: UI.blue
        case .secondary: hovering ? UI.blue.opacity(0.18) : UI.muted.opacity(0.12)
        case .danger: UI.red
        }
    }
}

private struct ProductiveButton: ButtonStyle {
    enum Kind { case primary, secondary, danger }
    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        ProductiveButtonBody(label: configuration.label, kind: kind, pressed: configuration.isPressed)
    }
}

private struct ProductiveFocus: ViewModifier {
    let kind: ProductiveButton.Kind
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .focusEffectDisabled()
            .overlay {
                if focused {
                    ZStack(alignment: .leading) {
                        if kind == .secondary { UI.blue.opacity(0.18) }
                        RoundedRectangle(cornerRadius: UI.radius)
                            .fill(kind == .secondary ? UI.blue : Color.white)
                            .frame(width: 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .allowsHitTesting(false)
                    .clipShape(RoundedRectangle(cornerRadius: UI.radius, style: .continuous))
                }
            }
    }
}

private extension View {
    func productiveFocus(_ kind: ProductiveButton.Kind) -> some View {
        modifier(ProductiveFocus(kind: kind))
    }
}

private struct ChoiceButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                ZStack {
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                    }
                }
                .frame(width: 13, height: 13)
                Text(title).lineLimit(1)
            }
            .font(.system(.caption, weight: .medium))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(
                selected ? UI.blue : ((focused || hovering) ? UI.blue.opacity(0.18) : UI.muted.opacity(0.10)),
                in: RoundedRectangle(cornerRadius: UI.radius, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: UI.radius, style: .continuous))
        }
        .buttonStyle(.plain)
        .focused($focused)
        .focusEffectDisabled()
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onHover { value in
            withAnimation(reduceMotion ? nil : .easeOut(duration: UI.hoverDuration)) { hovering = value }
        }
    }
}

private struct Eyebrow: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.1)
            .foregroundStyle(UI.muted)
    }
}

private struct SectionHeading: View {
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).font(.system(.title3, weight: .semibold))
            Spacer(minLength: 12)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(UI.muted).monospacedDigit()
            }
        }
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct DefinitionRow: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(UI.muted)
                .frame(width: 104, alignment: .leading)
            Text(value)
                .font(monospaced ? .system(.caption, design: .monospaced) : .body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct AccountWindow: View {
    @ObservedObject var model: AccountViewModel
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var focusedAccountID: UUID?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 244)
            ZStack(alignment: .top) {
                if reduceTransparency { UI.canvasFallback } else { MaterialPane(material: .contentBackground) }
                Group {
                    if let account = model.selectedAccount {
                        AccountDetail(account: account, model: model)
                            .id(account.id)
                    } else {
                        EmptyAccountView(
                            hasAccounts: !(model.status?.accounts.isEmpty ?? true)
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let error = model.errorMessage, !model.showImport {
                    ErrorBanner(message: error) { model.errorMessage = nil }
                        .padding(.top, 12)
                        .padding(.horizontal, 18)
                }
            }
        }
        .background(WindowChrome())
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented: $model.showImport) { ImportSheet(model: model) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.load() } }
        }
    }

    private var sidebar: some View {
        ZStack {
            if reduceTransparency { UI.sidebarFallback } else { MaterialPane(material: .sidebar) }
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 8) {
                    Text("AI Manager")
                        .font(.system(.headline, weight: .semibold))
                    Spacer()
                    Text("\(model.status?.accounts.count ?? 0)")
                        .font(.system(.caption, design: .monospaced, weight: .medium))
                        .foregroundStyle(UI.muted)
                        .monospacedDigit()
                        .accessibilityLabel("\(model.status?.accounts.count ?? 0) accounts")
                }
                .padding(.leading, 78)
                .padding(.trailing, 14)
                .frame(height: 48)
                .contentShape(Rectangle())

                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(model.status?.accounts ?? []) { account in
                            Button {
                                model.selectedAccountID = account.id
                            } label: {
                                AccountRow(
                                    account: account,
                                    isDefault: account.id == model.status?.defaultAccountID,
                                    isSelected: account.id == model.selectedAccountID,
                                    isFocused: account.id == focusedAccountID
                                )
                            }
                            .buttonStyle(.plain)
                            .focused($focusedAccountID, equals: account.id)
                            .focusEffectDisabled()
                            .accessibilityLabel(account.identity.displayName)
                            .accessibilityValue(
                                "\(account.id == model.selectedAccountID ? "Selected, " : "")\(account.id == model.status?.defaultAccountID ? "Default, " : "")\(account.verification.state.label)"
                            )
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .onMoveCommand(perform: moveSelection)

                VStack(spacing: 8) {
                    if model.isBusy {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text("Working…").font(.caption).foregroundStyle(UI.muted)
                            Spacer()
                        }
                    }
                    if let pending = model.status?.pendingRecovery, !pending.isEmpty {
                        Button("Recover \(pending.count) Operation\(pending.count == 1 ? "" : "s")") {
                            Task { await model.recover() }
                        }
                        .buttonStyle(ProductiveButton(kind: .danger))
                        .productiveFocus(.danger)
                        .disabled(model.isBusy)
                    }
                    Button {
                        Task { await model.beginImport() }
                    } label: {
                        Label("Import Account", systemImage: "plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ProductiveButton(kind: .primary))
                    .productiveFocus(.primary)
                    .disabled(model.isBusy)
                }
                .padding(10)
            }
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard direction == .up || direction == .down else { return }
        let accounts = model.status?.accounts ?? []
        guard !accounts.isEmpty else { return }
        let current = accounts.firstIndex { $0.id == model.selectedAccountID }
        let next: Int
        if direction == .up {
            next = max(0, (current ?? 1) - 1)
        } else {
            next = min(accounts.count - 1, (current ?? -1) + 1)
        }
        model.selectedAccountID = accounts[next].id
        focusedAccountID = accounts[next].id
    }
}

private struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(UI.red)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Action could not finish").font(.system(.body, weight: .semibold))
                Text(message).font(.caption).textSelection(.enabled)
            }
            Spacer(minLength: 12)
            Button(action: dismiss) {
                Image(systemName: "xmark").frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss error")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(UI.red.opacity(0.12), in: RoundedRectangle(cornerRadius: UI.radius, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

private struct AccountRow: View {
    let account: AccountRecord
    let isDefault: Bool
    let isSelected: Bool
    let isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: UI.radius)
                .fill(isSelected || isFocused ? UI.blue : .clear)
                .frame(width: isFocused ? 5 : 3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                Text(account.identity.displayName).font(.system(.body, weight: .medium)).lineLimit(2)
                HStack(spacing: 8) {
                    if isDefault {
                        Label("Default", systemImage: "checkmark.circle.fill").foregroundStyle(UI.blue)
                    }
                    Label(account.verification.state.label, systemImage: account.verification.state.icon)
                        .foregroundStyle(account.verification.state.tint)
                }
                .font(.caption)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        }
        .background(
            isSelected ? UI.blue.opacity(0.16) : ((isFocused || hovering) ? UI.blue.opacity(0.09) : Color.clear),
            in: RoundedRectangle(cornerRadius: UI.radius, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: UI.radius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover { value in
            withAnimation(reduceMotion ? nil : .easeOut(duration: UI.hoverDuration)) { hovering = value }
        }
    }
}

private struct EmptyAccountView: View {
    let hasAccounts: Bool

    var body: some View {
        VStack(alignment: .leading) {
            Spacer()
            HStack(alignment: .top, spacing: 24) {
                ZStack {
                    RoundedRectangle(cornerRadius: UI.radius).fill(UI.blue)
                    Image(systemName: hasAccounts ? "person.crop.circle" : "person.crop.circle.badge.plus")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.white)
                }
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 14) {
                    Text(hasAccounts ? "Select an account" : "Import your first account")
                        .font(.system(size: 26, weight: .semibold))
                        .tracking(-0.4)
                    Text(hasAccounts
                         ? "Choose an account in the sidebar to review its profile, verification, and launch options."
                         : "Choose a Codex home to bring in credentials, shared settings, and chat history with a reviewable backup.")
                        .font(.body)
                        .foregroundStyle(UI.muted)
                        .lineSpacing(3)
                        .frame(maxWidth: 520, alignment: .leading)
                }
            }
            Spacer()
        }
        .padding(32)
        .frame(maxWidth: 820, maxHeight: .infinity, alignment: .leading)
    }
}

private struct AccountDetail: View {
    let account: AccountRecord
    @ObservedObject var model: AccountViewModel
    @State private var detailsExpanded = false

    private var linkIssues: [LinkedSettingsDivergence] {
        model.status?.linkedSettingsDivergences.filter { $0.accountID == account.id } ?? []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if !linkIssues.isEmpty { repairs }
                actions
                profile
                if let notice = model.notice {
                    Label(notice, systemImage: "info.circle.fill")
                        .font(.caption)
                        .foregroundStyle(UI.blue)
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(UI.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: UI.radius))
                        .accessibilityLabel("Status: \(notice)")
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 28)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .navigationTitle(account.identity.displayName)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(account.identity.heroName)
                .font(.system(size: 26, weight: .semibold))
                .tracking(-0.4)
                .lineLimit(2)
                .textSelection(.enabled)
            HStack(spacing: 10) {
                if account.id == model.status?.defaultAccountID {
                    Label("Default", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(UI.blue)
                }
                if let workspace = account.identity.workspaceID {
                    Text(workspace).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }
            .font(.caption)
            .foregroundStyle(UI.muted)
            Text(account.verification.detail)
                .font(.caption)
                .foregroundStyle(UI.muted)
                .textSelection(.enabled)
                .frame(maxWidth: 660, alignment: .leading)
        }
    }

    private var profile: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                detailsExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: detailsExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Account details")
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(ProductiveButton(kind: .secondary))
            .productiveFocus(.secondary)
            .accessibilityValue(detailsExpanded ? "Expanded" : "Collapsed")

            if detailsExpanded {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                    DefinitionRow(label: "Profile", value: account.home.path, monospaced: true)
                    DefinitionRow(label: "Source", value: account.source.path, monospaced: true)
                    DefinitionRow(label: "Settings", value: model.paths.sharedRoot.path, monospaced: true)
                    DefinitionRow(label: "Imported", value: account.importedAt.formatted(date: .abbreviated, time: .shortened))
                }
                Button("Show Shared Settings in Finder") { model.showSharedRoot() }
                    .buttonStyle(ProductiveButton(kind: .secondary))
                    .productiveFocus(.secondary)
            }
        }
    }

    private var repairs: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeading(title: "Shared Settings Need Repair", detail: "\(linkIssues.count) found")
            Label(
                "A local editor replaced shared links. Review each path before you back up the local entry and restore its intended link.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(UI.orange)
            ForEach(linkIssues) { issue in
                VStack(alignment: .leading, spacing: 12) {
                    Text(issue.relativePath).font(.system(.headline, design: .monospaced)).textSelection(.enabled)
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                        DefinitionRow(label: "Local entry", value: issue.localPath.path, monospaced: true)
                        DefinitionRow(label: "Target", value: issue.intendedTarget.path, monospaced: true)
                        DefinitionRow(label: "Fingerprint", value: issue.localFingerprint, monospaced: true)
                        DefinitionRow(label: "Backup root", value: issue.backupRoot.path, monospaced: true)
                    }
                    Button("Back Up Local Entry and Repair Link") {
                        Task { await model.repairLinkedSetting(issue) }
                    }
                    .buttonStyle(ProductiveButton(kind: .danger))
                    .productiveFocus(.danger)
                    .disabled(model.isBusy)
                }
                .padding(16)
                .background(UI.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: UI.radius))
            }
        }
    }

    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                useDefaultButton
                openAccountButton
                verifyButton
                copyPathButton
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    useDefaultButton
                    openAccountButton
                }
                GridRow {
                    verifyButton
                    copyPathButton
                }
            }
        }
    }

    private var useDefaultButton: some View {
        Button("Use by Default") { Task { await model.switchDefault() } }
            .buttonStyle(ProductiveButton(kind: .primary))
            .productiveFocus(.primary)
            .keyboardShortcut("d", modifiers: [.command])
            .help("Use this account for future default-home sessions")
            .accessibilityHint("Changes future default-home Codex sessions. Existing sessions keep their current account.")
            .disabled(account.id == model.status?.defaultAccountID || model.isBusy)
    }

    private var openAccountButton: some View {
        Button("Open with This Account") { Task { await model.openAccount() } }
            .buttonStyle(ProductiveButton(kind: .secondary))
            .productiveFocus(.secondary)
            .keyboardShortcut(.return, modifiers: [.command])
            .help("Open a new session with this account")
            .disabled(model.isBusy || !linkIssues.isEmpty)
    }

    private var verifyButton: some View {
        Button("Verify Locally") { Task { await model.verify() } }
            .buttonStyle(ProductiveButton(kind: .secondary))
            .productiveFocus(.secondary)
            .keyboardShortcut("v", modifiers: [.command, .shift])
            .disabled(model.isBusy)
    }

    private var copyPathButton: some View {
        Button("Copy Profile Path") { model.copyProfilePath() }
            .buttonStyle(ProductiveButton(kind: .secondary))
            .productiveFocus(.secondary)
    }
}

private struct ImportSheet: View {
    @ObservedObject var model: AccountViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if reduceTransparency { UI.canvasFallback } else { MaterialPane(material: .contentBackground) }
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    Text(importTitle).font(.system(.title2, weight: .semibold))
                    Spacer()
                    ImportStepRail(step: importStep)
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(ProductiveButton(kind: .secondary))
                        .productiveFocus(.secondary)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)

                if let error = model.errorMessage {
                    ErrorBanner(message: error) { model.errorMessage = nil }
                        .padding(.horizontal, 24)
                }

                Group {
                    if let result = model.importResult {
                        ImportResultView(result: result)
                    } else if let plan = model.importPlan {
                        ImportReview(plan: plan, model: model)
                    } else {
                        SourceChooser(model: model)
                    }
                }
                .padding(24)
                .disabled(model.isBusy)

                if model.isBusy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Working…").font(.caption).foregroundStyle(UI.muted)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Working")
                    .padding(.bottom, 12)
                }
            }
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 520, idealHeight: 660)
    }

    private var importStep: Int { model.importResult != nil ? 3 : (model.importPlan != nil ? 2 : 1) }
    private var importTitle: String {
        guard let result = model.importResult else { return model.importPlan == nil ? "Import Account" : "Review Import" }
        return result.unresolved.isEmpty ? "Import Complete" : "Import Needs Attention"
    }
}

private struct ImportStepRail: View {
    let step: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...3, id: \.self) { item in
                HStack(spacing: 6) {
                    Text("\(item)")
                        .font(.system(.caption2, design: .monospaced, weight: .semibold))
                        .foregroundStyle(item <= step ? Color.white : UI.muted)
                        .frame(width: 22, height: 22)
                        .background(item <= step ? UI.blue : UI.muted.opacity(0.10), in: RoundedRectangle(cornerRadius: UI.radius))
                    if item < 3 {
                        RoundedRectangle(cornerRadius: UI.radius).fill(item < step ? UI.blue : UI.muted.opacity(0.18)).frame(width: 18, height: 2)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Import step \(step) of 3")
    }
}

private struct SourceChooser: View {
    @ObservedObject var model: AccountViewModel
    @FocusState private var focusedSourceID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeading(title: "Choose a Source", detail: "\(model.discoveries.count) detected")
            Text("Choose a detected Codex home, or select a folder or auth.json file.").foregroundStyle(UI.muted)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.discoveries) { source in
                        Button {
                            model.selectedSourceID = source.id
                        } label: {
                            SourceRow(
                                source: source,
                                selected: source.id == model.selectedSourceID,
                                focused: source.id == focusedSourceID
                            )
                        }
                        .buttonStyle(.plain)
                        .focused($focusedSourceID, equals: source.id)
                        .focusEffectDisabled()
                        .accessibilityLabel(source.identity?.displayName ?? source.support.label)
                        .accessibilityValue("\(source.id == model.selectedSourceID ? "Selected, " : "")\(source.support.label)")
                        .accessibilityHint(source.path.path)
                    }
                }
            }
            .background(UI.muted.opacity(0.05), in: RoundedRectangle(cornerRadius: UI.radius))
            .onMoveCommand(perform: moveSelection)

            VStack(alignment: .leading, spacing: 10) {
                Eyebrow(text: "Import scope")
                HStack(spacing: 8) {
                    ChoiceButton(title: "Auth only", selected: model.importMode == .authOnly) {
                        model.importMode = .authOnly
                    }
                    ChoiceButton(title: "Auth, settings, and chats", selected: model.importMode == .full) {
                        model.importMode = .full
                    }
                }
                Text(model.importMode == .authOnly
                     ? "Imports credentials and links existing shared settings and chats. The source stays unchanged."
                     : "Reviews settings conflicts and adds source chats to the shared library. Changes are backed up first.")
                    .font(.caption)
                    .foregroundStyle(UI.muted)
            }
            HStack(spacing: 12) {
                Button("Choose Other...") { Task { await model.chooseSource() } }
                    .buttonStyle(ProductiveButton(kind: .secondary))
                    .productiveFocus(.secondary)
                    .keyboardShortcut("o", modifiers: [.command])
                Button("Refresh") { Task { await model.discover() } }
                    .buttonStyle(ProductiveButton(kind: .secondary))
                    .productiveFocus(.secondary)
                    .keyboardShortcut("r", modifiers: [.command])
                Spacer()
                Button("Review Import") { Task { await model.reviewImport() } }
                    .buttonStyle(ProductiveButton(kind: .primary))
                    .productiveFocus(.primary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.selectedSourceID == nil || model.isBusy || model.discoveries.first(where: { $0.id == model.selectedSourceID })?.support != .supportedChatGPT)
            }
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard direction == .up || direction == .down, !model.discoveries.isEmpty else { return }
        let current = model.discoveries.firstIndex { $0.id == model.selectedSourceID }
        let next: Int
        if direction == .up {
            next = max(0, (current ?? 1) - 1)
        } else {
            next = min(model.discoveries.count - 1, (current ?? -1) + 1)
        }
        model.selectedSourceID = model.discoveries[next].id
        focusedSourceID = model.discoveries[next].id
    }
}

private struct SourceRow: View {
    let source: DiscoveredSource
    let selected: Bool
    let focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: UI.radius)
                .fill(selected || focused ? UI.blue : .clear)
                .frame(width: focused ? 5 : 4)
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text(source.identity?.displayName ?? source.support.label).font(.system(.body, weight: .medium))
                    Spacer()
                    Label(source.support.label, systemImage: source.support == .supportedChatGPT ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(source.support == .supportedChatGPT ? UI.teal : UI.orange)
                }
                Text(source.path.path)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(2)
                    .textSelection(.enabled)
                Text("\(source.settings.count) settings · \(source.history.activeTranscripts) active · \(source.history.archivedTranscripts) archived chats")
                    .font(.caption)
                    .foregroundStyle(UI.muted)
                    .monospacedDigit()
                if let error = source.inspectionError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(UI.orange)
                }
            }
            .padding(14)
        }
        .background(
            selected ? UI.blue.opacity(0.16) : ((focused || hovering) ? UI.blue.opacity(0.09) : UI.surface),
            in: RoundedRectangle(cornerRadius: UI.radius)
        )
        .contentShape(RoundedRectangle(cornerRadius: UI.radius))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onHover { value in
            withAnimation(reduceMotion ? nil : .easeOut(duration: UI.hoverDuration)) { hovering = value }
        }
    }
}

private struct ImportReview: View {
    let plan: ImportPlan
    @ObservedObject var model: AccountViewModel

    private var choicesComplete: Bool { plan.conflicts.allSatisfy { model.conflictChoices[$0.relativePath] != nil } }
    private var externalReviewsComplete: Bool {
        plan.conflicts.allSatisfy {
            model.conflictChoices[$0.relativePath] != .useImported || $0.externalTarget == nil || $0.externalTargetBytes != nil
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    summary
                    if !plan.warnings.isEmpty { warnings }
                    if !plan.conflicts.isEmpty { conflicts }
                    manifest
                }
            }
            HStack {
                Button("Back") { model.resetImport() }
                    .buttonStyle(ProductiveButton(kind: .secondary))
                    .productiveFocus(.secondary)
                    .keyboardShortcut("[", modifiers: [.command])
                Spacer()
                Button("Import Account") { Task { await model.commitImport() } }
                    .buttonStyle(ProductiveButton(kind: .primary))
                    .productiveFocus(.primary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!choicesComplete || !externalReviewsComplete || model.isBusy)
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeading(title: "Review the Plan", detail: "\(plan.manifest.filter(\.selected).count) selected")
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                DefinitionRow(label: "Account", value: plan.identity.displayName)
                DefinitionRow(label: "Destination", value: plan.destination.path, monospaced: true)
                DefinitionRow(label: "Backup", value: plan.backup.path, monospaced: true)
                DefinitionRow(label: "Space needed", value: ByteCountFormatter.string(fromByteCount: plan.requiredBytes, countStyle: .file))
            }
        }
    }

    private var warnings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "Warnings")
            ForEach(plan.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(UI.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(UI.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: UI.radius))
            }
        }
    }

    private var conflicts: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "Conflicts · \(plan.conflicts.count)")
            ForEach(plan.conflicts) { conflict in
                VStack(alignment: .leading, spacing: 10) {
                    Text(conflict.relativePath).font(.system(.headline, design: .monospaced)).textSelection(.enabled)
                    Text(conflict.affectsAllAccounts
                         ? "This settings choice affects every linked account."
                         : "The managed credential differs from this source. Choose which credential to keep.")
                        .font(.caption)
                        .foregroundStyle(UI.muted)
                    if let target = conflict.externalTarget {
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                            DefinitionRow(label: "Linked target", value: target.path, monospaced: true)
                            if let bytes = conflict.externalTargetBytes {
                                DefinitionRow(label: "Reviewed size", value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                                DefinitionRow(label: "Fingerprint", value: conflict.importedDigest, monospaced: true)
                            }
                        }
                        if model.conflictChoices[conflict.relativePath] == .useImported && conflict.externalTargetBytes == nil {
                            Label("Review this linked target before importing it.", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(UI.orange)
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            ChoiceButton(
                                title: "Choose...",
                                selected: model.conflictChoices[conflict.relativePath] == nil
                            ) { model.conflictChoices[conflict.relativePath] = nil }
                            ChoiceButton(
                                title: conflict.affectsAllAccounts ? "Keep shared" : "Keep managed",
                                selected: model.conflictChoices[conflict.relativePath] == .keepShared
                            ) { model.conflictChoices[conflict.relativePath] = .keepShared }
                            ChoiceButton(
                                title: "Use imported",
                                selected: model.conflictChoices[conflict.relativePath] == .useImported
                            ) { model.conflictChoices[conflict.relativePath] = .useImported }
                        }
                        if conflict.externalTarget != nil,
                           model.conflictChoices[conflict.relativePath] == .useImported,
                           conflict.externalTargetBytes == nil {
                            Button("Review Linked Data") { Task { await model.reviewExternalSetting(conflict.relativePath) } }
                                .buttonStyle(ProductiveButton(kind: .secondary))
                                .productiveFocus(.secondary)
                                .disabled(model.isBusy)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(UI.muted.opacity(0.08), in: RoundedRectangle(cornerRadius: UI.radius))
            }
        }
    }

    private var manifest: some View {
        DisclosureGroup {
            LazyVStack(spacing: 0) {
                ForEach(plan.manifest) { entry in
                    HStack(spacing: 10) {
                        Image(systemName: entry.selected ? "checkmark.circle.fill" : "minus.circle")
                            .foregroundStyle(entry.selected ? UI.teal : UI.muted)
                        Text(entry.relativePath).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Spacer()
                        Text(entry.disposition).font(.caption).foregroundStyle(UI.muted)
                    }
                    .padding(.vertical, 8)
                }
            }
        } label: {
            Text("Files in this import (\(plan.manifest.count))").font(.system(.body, weight: .medium))
        }
    }
}

private struct ImportResultView: View {
    let result: ImportResult
    private var complete: Bool { result.unresolved.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .top, spacing: 18) {
                    ZStack {
                        RoundedRectangle(cornerRadius: UI.radius).fill(complete ? UI.teal : UI.orange)
                        Image(systemName: complete ? "checkmark" : "exclamationmark")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 60, height: 60)
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Eyebrow(text: complete ? "Import complete" : "Review required")
                        Text(complete ? "Account imported" : "Imported with unresolved items")
                            .font(.system(size: 26, weight: .semibold))
                        Text(result.verification.detail).foregroundStyle(UI.muted)
                    }
                }
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeading(title: "Import Result", detail: "\(result.importedChats) chats")
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                        DefinitionRow(label: "Profile", value: result.account.home.path, monospaced: true)
                        DefinitionRow(label: "Backup", value: result.backup.path, monospaced: true)
                        DefinitionRow(label: "Imported", value: "\(result.importedFiles) files and \(result.importedChats) chats")
                    }
                }
                if !result.unresolved.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Eyebrow(text: "Unresolved items · \(result.unresolved.count)")
                        ForEach(result.unresolved, id: \.self) { item in
                            Label(item, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(UI.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(UI.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: UI.radius))
                        }
                    }
                }
                Text("The imported account is not the default until you choose Use by Default.")
                    .foregroundStyle(UI.muted)
            }
            .frame(maxWidth: 760, alignment: .leading)
        }
    }
}

private extension AccountIdentity {
    var heroName: String { email ?? accountID ?? "Unresolved account" }

    var displayName: String {
        if let email, let workspaceID { return "\(email) · \(workspaceID)" }
        return email ?? accountID ?? "Unresolved account"
    }
}

private extension VerificationState {
    var label: String {
        switch self {
        case .imported: "Imported"
        case .needsSignIn: "Needs sign-in"
        case .verifiedLocally: "Verified locally"
        case .verifiedWithCodex: "Verified with Codex"
        case .unsupported: "Unsupported"
        }
    }

    var icon: String {
        switch self {
        case .verifiedLocally, .verifiedWithCodex: "checkmark.circle"
        case .needsSignIn: "person.crop.circle.badge.exclamationmark"
        case .unsupported: "xmark.circle"
        case .imported: "tray.and.arrow.down"
        }
    }

    var tint: Color {
        switch self {
        case .verifiedLocally, .verifiedWithCodex: UI.teal
        case .needsSignIn: UI.orange
        case .unsupported: UI.red
        case .imported: UI.blue
        }
    }
}

private extension SourceSupport {
    var label: String {
        switch self {
        case .supportedChatGPT: "ChatGPT account"
        case .apiKey: "API key is outside v1"
        case .missingAuth: "Missing auth.json"
        case .malformedAuth: "Malformed auth.json"
        case .keychainOnly: "Keychain-only auth is unsupported"
        case .unknown: "Unknown auth format"
        }
    }
}
