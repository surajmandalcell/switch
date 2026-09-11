import AppKit
import SwiftUI
import AIManagerCore

private enum UI {
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let sidebar = Color(nsColor: .underPageBackgroundColor)
    static let muted = Color(nsColor: .secondaryLabelColor)
    static let blue = Color(nsColor: .systemBlue)
    static let teal = Color(nsColor: .systemTeal)
    static let orange = Color(nsColor: .systemOrange)
    static let red = Color(nsColor: .systemRed)
}

private struct ProductiveButton: ButtonStyle {
    enum Kind { case primary, secondary, danger }
    let kind: Kind
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, weight: .medium))
            .foregroundStyle(kind == .secondary ? Color.primary : Color.white)
            .padding(.horizontal, 16)
            .frame(minHeight: 36)
            .background(
                fill.opacity(configuration.isPressed ? 0.78 : 1),
                ignoresSafeAreaEdges: []
            )
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.42)
    }

    private var fill: Color {
        switch kind {
        case .primary: UI.blue
        case .secondary: UI.muted.opacity(0.12)
        case .danger: UI.red
        }
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
                        Rectangle()
                            .fill(kind == .secondary ? UI.blue : Color.white)
                            .frame(width: 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .allowsHitTesting(false)
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
            .background(selected ? UI.blue : (focused ? UI.blue.opacity(0.18) : UI.muted.opacity(0.10)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .focusEffectDisabled()
        .accessibilityAddTraits(selected ? .isSelected : [])
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
    let index: String
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(index)
                .font(.system(.caption, design: .monospaced, weight: .semibold))
                .foregroundStyle(UI.blue)
                .frame(width: 24, alignment: .leading)
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

    var body: some View {
        VStack(spacing: 0) {
            WindowHeader(model: model)
            if let error = model.errorMessage, !model.showImport {
                ErrorBanner(message: error) { model.errorMessage = nil }
            }
            HStack(spacing: 0) {
                sidebar.frame(width: 232)
                Group {
                    if let account = model.selectedAccount {
                        AccountDetail(account: account, model: model)
                            .id(account.id)
                    } else {
                        EmptyAccountView(
                            hasAccounts: !(model.status?.accounts.isEmpty ?? true),
                            isBusy: model.isBusy
                        ) {
                            Task { await model.beginImport() }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(UI.canvas)
            }
            StatusBar(model: model)
        }
        .background(UI.canvas)
        .sheet(isPresented: $model.showImport) { ImportSheet(model: model) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.load() } }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow(text: "AI Manager")
                Spacer()
                Text("\(model.status?.accounts.count ?? 0)")
                    .font(.system(.caption, design: .monospaced, weight: .medium))
                    .foregroundStyle(UI.muted)
                    .monospacedDigit()
                    .accessibilityLabel("\(model.status?.accounts.count ?? 0) accounts")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(UI.sidebar)

            ScrollView {
                LazyVStack(spacing: 0) {
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
            }
            .background(UI.sidebar)
            .onMoveCommand(perform: moveSelection)
            .overlay {
                if model.status?.accounts.isEmpty == true {
                    VStack(spacing: 10) {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.system(size: 24, weight: .light))
                            .foregroundStyle(UI.blue)
                        Text("No accounts yet").font(.system(.body, weight: .medium))
                        Text("Import a Codex home to start.")
                            .font(.caption)
                            .foregroundStyle(UI.muted)
                            .multilineTextAlignment(.center)
                    }
                    .padding(20)
                    .accessibilityElement(children: .combine)
                }
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
        .background(UI.red.opacity(0.10))
        .accessibilityElement(children: .contain)
    }
}

private struct WindowHeader: View {
    @ObservedObject var model: AccountViewModel

    var body: some View {
        HStack(spacing: 14) {
            Color.clear.frame(width: 62, height: 1).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("AI Manager").font(.system(.headline, weight: .semibold))
                Text("Codex accounts").font(.caption).foregroundStyle(UI.muted)
            }
            Spacer()
            if let selected = model.selectedAccount {
                Text(selected.identity.displayName)
                    .font(.caption)
                    .foregroundStyle(UI.muted)
                    .lineLimit(1)
            }
            Button {
                Task { await model.beginImport() }
            } label: {
                Label("Import Account", systemImage: "plus")
            }
            .buttonStyle(ProductiveButton(kind: .primary))
            .productiveFocus(.primary)
            .help("Import a Codex account")
            .disabled(model.isBusy)
        }
        .padding(.horizontal, 16)
        .background(UI.surface)
    }
}

private struct AccountRow: View {
    let account: AccountRecord
    let isDefault: Bool
    let isSelected: Bool
    let isFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
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
        .background(isSelected ? UI.blue.opacity(0.14) : (isFocused ? UI.blue.opacity(0.08) : Color.clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct EmptyAccountView: View {
    let hasAccounts: Bool
    let isBusy: Bool
    let importAction: () -> Void

    var body: some View {
        VStack(alignment: .leading) {
            Spacer()
            HStack(alignment: .top, spacing: 24) {
                ZStack {
                    Rectangle().fill(UI.blue)
                    Image(systemName: hasAccounts ? "person.crop.circle" : "person.crop.circle.badge.plus")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.white)
                }
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 14) {
                    Eyebrow(text: hasAccounts ? "Account library" : "Get started")
                    Text(hasAccounts ? "Select an account" : "Bring your Codex accounts together.")
                        .font(.system(size: 28, weight: .semibold))
                        .tracking(-0.5)
                    Text(hasAccounts
                         ? "Choose an account in the sidebar to review its profile, verification, and launch options."
                         : "Import credentials, share settings, and preserve chat history with a reviewable backup before each change.")
                        .font(.body)
                        .foregroundStyle(UI.muted)
                        .lineSpacing(3)
                        .frame(maxWidth: 520, alignment: .leading)
                    if !hasAccounts {
                        Button("Import Account", action: importAction)
                            .buttonStyle(ProductiveButton(kind: .primary))
                            .productiveFocus(.primary)
                            .keyboardShortcut(.defaultAction)
                            .disabled(isBusy)
                    }
                }
            }
            Spacer()
        }
        .padding(40)
        .frame(maxWidth: 820, maxHeight: .infinity, alignment: .leading)
    }
}

private struct AccountDetail: View {
    let account: AccountRecord
    @ObservedObject var model: AccountViewModel

    private var linkIssues: [LinkedSettingsDivergence] {
        model.status?.linkedSettingsDivergences.filter { $0.accountID == account.id } ?? []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                header
                if !linkIssues.isEmpty { repairs }
                actions
                profile
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 32)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .navigationTitle(account.identity.displayName)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Rectangle().fill(UI.blue).frame(width: 8, height: 64).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .center, spacing: 10) {
                        Eyebrow(text: account.id == model.status?.defaultAccountID ? "Default account" : "Managed account")
                        Spacer(minLength: 0)
                        Label(account.verification.state.label, systemImage: account.verification.state.icon)
                            .font(.system(.caption, weight: .semibold))
                            .foregroundStyle(account.verification.state.tint)
                            .padding(.horizontal, 10)
                            .frame(minHeight: 28)
                            .background(account.verification.state.tint.opacity(0.12))
                    }
                    Text(account.identity.heroName)
                        .font(.system(size: 30, weight: .semibold))
                        .tracking(-0.6)
                        .textSelection(.enabled)
                    if let workspace = account.identity.workspaceID {
                        Text("Workspace \(workspace)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(UI.muted)
                            .textSelection(.enabled)
                    }
                }
                .layoutPriority(1)
            }
            Text(account.verification.detail)
                .foregroundStyle(UI.muted)
                .textSelection(.enabled)
                .frame(maxWidth: 660, alignment: .leading)
        }
    }

    private var profile: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeading(index: linkIssues.isEmpty ? "02" : "03", title: "Profile", detail: account.importedAt.formatted(date: .abbreviated, time: .shortened))
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                DefinitionRow(label: "Profile", value: account.home.path, monospaced: true)
                DefinitionRow(label: "Source", value: account.source.path, monospaced: true)
                DefinitionRow(label: "Settings", value: "Shared with \(model.paths.sharedRoot.path)", monospaced: true)
            }
        }
    }

    private var repairs: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeading(index: "01", title: "Shared Settings Need Repair", detail: "\(linkIssues.count) found")
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
                .background(UI.orange.opacity(0.07))
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeading(index: linkIssues.isEmpty ? "01" : "02", title: "Account Actions")
            Text("Changing the default affects future sessions that use the default Codex home. Existing sessions keep their current account.")
                .foregroundStyle(UI.muted)
                .frame(maxWidth: 650, alignment: .leading)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    useDefaultButton
                    openAccountButton
                    verifyButton
                    copyPathButton
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
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
    }

    private var useDefaultButton: some View {
        Button("Use by Default") { Task { await model.switchDefault() } }
            .buttonStyle(ProductiveButton(kind: .primary))
            .productiveFocus(.primary)
            .keyboardShortcut("d", modifiers: [.command])
            .help("Use this account for future default-home sessions")
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

private struct StatusBar: View {
    @ObservedObject var model: AccountViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle().fill(model.isBusy ? UI.orange : UI.teal).frame(width: 7, height: 7).accessibilityHidden(true)
                if model.isBusy { ProgressView().controlSize(.small).accessibilityLabel("Working") }
                if let status = model.status {
                    Text("SHARED").font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(UI.muted)
                    Text(status.sharedRoot.path)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Show in Finder") { model.showSharedRoot() }.buttonStyle(.plain)
                    if !status.pendingRecovery.isEmpty {
                        Button("Recover \(status.pendingRecovery.count)") { Task { await model.recover() } }
                            .buttonStyle(ProductiveButton(kind: .danger))
                            .productiveFocus(.danger)
                            .disabled(model.isBusy)
                    }
                } else {
                    Text("Loading accounts...").font(.caption)
                    Spacer()
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 34)
            .accessibilityElement(children: .contain)
            if let notice = model.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(UI.muted)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Status: \(notice)")
            }
        }
        .background(UI.surface)
    }
}

private struct ImportSheet: View {
    @ObservedObject var model: AccountViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow(text: "Codex account")
                    Text(importTitle).font(.system(.title2, weight: .semibold))
                }
                Spacer()
                ImportStepRail(step: importStep)
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(ProductiveButton(kind: .secondary))
                    .productiveFocus(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .background(UI.surface)

            if let error = model.errorMessage {
                ErrorBanner(message: error) { model.errorMessage = nil }
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
                    Text("Working...").font(.caption).foregroundStyle(UI.muted)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Working")
                .padding(.bottom, 12)
            }
        }
        .background(UI.canvas)
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
                        .background(item <= step ? UI.blue : UI.muted.opacity(0.10))
                    if item < 3 {
                        Rectangle().fill(item < step ? UI.blue : UI.muted.opacity(0.18)).frame(width: 18, height: 2)
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
            SectionHeading(index: "01", title: "Choose a Source", detail: "\(model.discoveries.count) detected")
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
            .background(UI.muted.opacity(0.04))
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

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
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
        .background(selected ? UI.blue.opacity(0.14) : (focused ? UI.blue.opacity(0.08) : UI.surface))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
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
            SectionHeading(index: "02", title: "Review the Plan", detail: "\(plan.manifest.filter(\.selected).count) selected")
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
                    .background(UI.orange.opacity(0.08))
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
                .background(UI.muted.opacity(0.06))
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
                        Rectangle().fill(complete ? UI.teal : UI.orange)
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
                    SectionHeading(index: "03", title: "Import Result", detail: "\(result.importedChats) chats")
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
                                .background(UI.orange.opacity(0.08))
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
