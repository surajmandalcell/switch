import AIManagerCore
import AppKit
import SwiftUI

// Add Account: the searchable provider list and the two generic credential pages.

// MARK: - Provider list

struct ProviderChooserPage: View {
  @ObservedObject var model: AccountViewModel
  let step: Int
  let onContinue: () -> Void
  #if AI_MANAGER_PREVIEW
  @State private var query = PreviewArguments.value("add-query") ?? ""
  #else
  @State private var query = ""
  #endif
  @State private var hoveredID: ProviderID?
  @FocusState private var searchFocused: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var choices: [ProviderChoice] { ProviderChoices.all(descriptors: model.providers) }
  private var visible: [ProviderChoice] { ProviderChoices.filter(choices, query: query) }
  private var selected: ProviderChoice? { visible.first { $0.id == model.selectedProviderID } }

  var body: some View {
    let rows = visible
    VStack(spacing: 12) {
      searchField
      AIMScrollView {
        VStack(spacing: 0) {
          if rows.isEmpty {
            Text("No provider matches “\(query)”.")
              .font(AIMTheme.sans(12)).foregroundStyle(AIMTheme.muted)
              .padding(AIMTheme.panelContentInset)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          ForEach(Array(rows.enumerated()), id: \.element.id) { index, choice in
            row(choice, index: index)
          }
        }
      }
      .background(AIMTheme.panel2)
      .clipShape(RoundedRectangle(cornerRadius: AIMTheme.radius))
      .frame(maxHeight: .infinity)

      ImportFooter(step: step, labels: ["Provider", "Sign in", "Done"]) {
        AIMButton(title: "Advanced Import…", icon: .folder, disabled: model.isBusy) {
          Task { await model.beginAdvancedImport() }
        }
      } trailing: {
        AIMButton(
          title: "Continue", tone: .primary,
          disabled: selected?.available != true || model.isBusy,
          action: onContinue
        )
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(.horizontal, AIMTheme.modalOuterInset)
    .padding(.vertical, 16)
    .frame(maxHeight: .infinity, alignment: .top)
    .onAppear {
      searchFocused = true
      keepSelectionVisible()
    }
    .onChange(of: query) { _, _ in keepSelectionVisible() }
  }

  private var searchField: some View {
    HStack(spacing: 8) {
      AIMIcon(name: .search, size: 13).foregroundStyle(AIMTheme.muted)
      TextField("Search providers", text: $query)
        .textFieldStyle(.plain)
        .font(AIMTheme.sans(12))
        .focused($searchFocused)
        .onSubmit(onContinueIfPossible)
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .accessibilityLabel("Search providers")
      if !query.isEmpty {
        Button { query = ""; searchFocused = true } label: {
          AIMIcon(name: .close, size: 11).foregroundStyle(AIMTheme.muted)
            .frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(AIMPressButtonStyle())
        .accessibilityLabel("Clear search")
      }
    }
    .padding(.horizontal, 10)
    .frame(minWidth: 300, maxWidth: .infinity, minHeight: 30, maxHeight: 30)
    .background(AIMTheme.control)
    .clipShape(RoundedRectangle(cornerRadius: AIMTheme.radius))
  }

  private func row(_ choice: ProviderChoice, index: Int) -> some View {
    let isSelected = model.selectedProviderID == choice.id
    return Button {
      model.selectedProviderID = choice.id
      searchFocused = true
    } label: {
      HStack(spacing: 12) {
        ProviderMark(providerID: choice.id)
        VStack(alignment: .leading, spacing: 3) {
          Text(choice.name).font(AIMTheme.sans(12, weight: .semibold)).lineLimit(1)
          Text(choice.subtitle)
            .font(AIMTheme.sans(10))
            .foregroundStyle(isSelected ? AIMTheme.activeInk.opacity(0.74) : AIMTheme.muted)
            .lineLimit(1)
        }
        Spacer()
        if choice.available {
          AIMIcon(name: .check, size: 14).opacity(isSelected ? 1 : 0)
        } else {
          Badge(text: "WIP", color: AIMTheme.disabledControl, ink: AIMTheme.disabledInk)
        }
      }
      .padding(.horizontal, AIMTheme.panelContentInset)
      .frame(height: 54)
      .foregroundStyle(isSelected ? AIMTheme.activeInk : AIMTheme.ink)
      .background {
        AIMHoverBackground(
          base: isSelected ? AIMTheme.active
            : index.isMultiple(of: 2) ? AIMTheme.panel : AIMTheme.listStripe,
          highlight: AIMTheme.listHover, hovered: hoveredID == choice.id && !isSelected)
      }
      .background(ScrollWhenSelected(selected: isSelected))
      .contentShape(Rectangle())
    }
    .buttonStyle(AIMPressButtonStyle())
    .disabled(!choice.available)
    .opacity(choice.available ? 1 : 0.64)
    .simultaneousGesture(TapGesture(count: 2).onEnded {
      guard choice.available, !model.isBusy else { return }
      model.selectedProviderID = choice.id
      onContinue()
    })
    .onHover { hoveredID = $0 && choice.available ? choice.id : nil }
    .accessibilityLabel(choice.name)
    .accessibilityValue(isSelected ? "Selected" : "")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityHint(
      choice.available
        ? "Select this provider. Double-click to continue."
        : (choice.unavailableReason ?? "Account setup is not available in this version."))
  }

  private func move(_ offset: Int) {
    let rows = visible.filter(\.available)
    guard !rows.isEmpty else { return }
    let current = rows.firstIndex { $0.id == model.selectedProviderID }
    let next = current.map { min(max($0 + offset, 0), rows.count - 1) } ?? (offset > 0 ? 0 : rows.count - 1)
    model.selectedProviderID = rows[next].id
  }

  /// A search that hides the selected row moves the selection to the first match.
  private func keepSelectionVisible() {
    let rows = visible.filter(\.available)
    if !rows.contains(where: { $0.id == model.selectedProviderID }), let first = rows.first {
      model.selectedProviderID = first.id
    }
  }

  private func onContinueIfPossible() {
    guard selected?.available == true, !model.isBusy else { return }
    onContinue()
  }
}

/// Scrolls the enclosing native scroll view to keep the selected row on screen.
private struct ScrollWhenSelected: NSViewRepresentable {
  let selected: Bool

  func makeNSView(context: Context) -> NSView { NSView() }

  func updateNSView(_ view: NSView, context: Context) {
    guard selected else { return }
    DispatchQueue.main.async { view.scrollToVisible(view.bounds) }
  }
}

// MARK: - Typed credentials (.secret)

struct SecretCredentialsPage: View {
  let spec: ProviderSpec
  @ObservedObject var model: AccountViewModel
  let back: () -> Void
  @State private var values: [String: String] = [:]
  @State private var prefilled: [String: String] = [:]
  @FocusState private var focusedKey: String?

  private var isComplete: Bool {
    spec.fields.allSatisfy { field in
      field.optional || !(values[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  var body: some View {
    VStack(spacing: AIMTheme.modalSectionSpacing) {
      AIMPanel(title: "\(spec.name) credentials") {
        AIMScrollView {
          VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
              ProviderMark(providerID: spec.id, size: 32)
              VStack(alignment: .leading, spacing: 5) {
                Text("Add a \(spec.name) account").font(AIMTheme.sans(18, weight: .semibold))
                Text("Switch keeps these values in a private file on this Mac and uses them only to read usage.")
                  .font(AIMTheme.sans(12)).foregroundStyle(AIMTheme.muted)
                  .fixedSize(horizontal: false, vertical: true)
              }
            }
            ForEach(spec.fields, id: \.key) { field in
              fieldRow(field)
            }
          }
          .padding(20)
        }
      }
      .frame(maxHeight: .infinity)

      ImportFooter(step: 2, labels: ["Provider", "Credentials", "Done"]) {
        AIMButton(title: "Back", disabled: model.isBusy, action: back)
      } trailing: {
        AIMButton(title: "Save", tone: .primary, disabled: !isComplete || model.isBusy, action: save)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(.horizontal, AIMTheme.modalOuterInset)
    .padding(.vertical, 16)
    .frame(maxHeight: .infinity, alignment: .top)
    .task {
      for field in spec.fields where values[field.key] == nil {
        if let value = model.environmentPrefill(for: field) {
          values[field.key] = value
          prefilled[field.key] = field.env.first { ProcessInfo.processInfo.environment[$0] == value }
        }
      }
      focusedKey = spec.fields.first?.key
    }
  }

  @ViewBuilder private func fieldRow(_ field: CredentialField) -> some View {
    let binding = Binding(get: { values[field.key] ?? "" }, set: { values[field.key] = $0 })
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Text(field.title).font(AIMTheme.sans(12, weight: .semibold))
        if field.optional {
          Text("Optional").font(AIMTheme.sans(10)).foregroundStyle(AIMTheme.muted)
        }
      }
      Group {
        if field.secure {
          SecureField(field.placeholder ?? "Paste the \(field.title.lowercased())", text: binding)
        } else {
          TextField(field.placeholder ?? "", text: binding)
        }
      }
      .textFieldStyle(.roundedBorder)
      .privacySensitive(field.secure)
      .focused($focusedKey, equals: field.key)
      .onSubmit { if isComplete { save() } }
      .accessibilityLabel(field.optional ? "\(field.title), optional" : field.title)
      if let name = prefilled[field.key] {
        Text("Filled from \(name) in this app's environment.")
          .font(AIMTheme.sans(10)).foregroundStyle(AIMTheme.muted)
      }
    }
  }

  private func save() {
    guard isComplete, !model.isBusy else { return }
    Task { _ = await model.addProviderAccount(providerID: spec.id, fields: values) }
  }
}

// MARK: - CLI-owned sign-in (.files)

struct FilesCredentialsPage: View {
  let spec: ProviderSpec
  @ObservedObject var model: AccountViewModel
  let back: () -> Void
  @State private var identity: CredentialIdentity?
  @State private var loaded = false

  private var signedInText: String {
    guard let identity else { return loaded ? "No sign-in found" : "Looking for a sign-in…" }
    return "Signed in as \(identity.email ?? identity.key)"
  }

  var body: some View {
    VStack(spacing: AIMTheme.modalSectionSpacing) {
      AIMPanel(title: "\(spec.name) sign-in") {
        VStack(alignment: .leading, spacing: 16) {
          HStack(alignment: .top, spacing: 12) {
            ProviderMark(providerID: spec.id, size: 32)
            VStack(alignment: .leading, spacing: 5) {
              Text(signedInText)
                .font(AIMTheme.sans(18, weight: .semibold))
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
              Text(identity?.plan.map { "Plan: \($0.capitalized)" } ?? detailText)
                .font(AIMTheme.sans(12)).foregroundStyle(AIMTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
          Notice(text: noticeText, tone: identity == nil && loaded ? AIMTheme.amber : AIMTheme.blue)
          if let file = spec.files.first {
            HStack(spacing: 8) {
              Text("Read from").font(AIMTheme.sans(10)).foregroundStyle(AIMTheme.muted)
              AIMCopyablePath(path: "~/" + file.path).font(AIMTheme.mono(10))
                .foregroundStyle(AIMTheme.muted)
            }
          }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }

      ImportFooter(step: 2, labels: ["Provider", "Sign in", "Done"]) {
        AIMButton(title: "Back", disabled: model.isBusy, action: back)
        if spec.login != nil {
          AIMButton(title: "Sign in another account", disabled: model.isBusy) {
            model.selectedProviderID = spec.id
            Task { await model.startAccountLogin() }
          }
        }
      } trailing: {
        AIMButton(
          title: "Import current sign-in", tone: .primary,
          disabled: identity == nil || model.isBusy
        ) {
          Task { _ = await model.importLiveProviderAccount(providerID: spec.id) }
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(.horizontal, AIMTheme.modalOuterInset)
    .padding(.vertical, 16)
    .frame(maxHeight: .infinity, alignment: .top)
    .task(id: spec.id) {
      identity = await model.liveProviderIdentity(spec.id)
      loaded = true
    }
  }

  private var detailText: String {
    if identity != nil { return "This is the sign-in that \(spec.name) holds on this Mac right now." }
    return loaded ? "Sign in with the official \(spec.name) app or CLI first, then import it here."
      : "Reading the current sign-in without changing it."
  }

  private var noticeText: String {
    identity == nil
      ? (spec.login == nil
        ? "Sign in with the official app, then return here."
        : "Sign in with \(spec.name), or choose Sign in another account to do it from Switch.")
      : (spec.login == nil
        ? "Import saves this sign-in so Switch can switch back to it later."
        : "Import saves this sign-in. Sign in another account opens Terminal for a second login.")
  }
}
