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
  @FocusState private var searchFocused: Bool

  private var choices: [ProviderChoice] {
    ProviderChoices.all(descriptors: model.providers, signedIn: model.signedInProviderIDs)
  }
  private var visible: [ProviderChoice] { ProviderChoices.filter(choices, query: query) }
  private var selected: ProviderChoice? { visible.first { $0.id == model.selectedProviderID } }

  var body: some View {
    let rows = visible
    VStack(spacing: AIMTheme.sectionSpacing) {
      searchField
      ScrollViewReader { proxy in
        List(selection: Binding(
          get: { model.selectedProviderID },
          set: { if let id = $0 { model.selectedProviderID = id; searchFocused = true } })
        ) {
          if rows.isEmpty {
            Text("No provider matches “\(query)”.").aimText(.secondary)
          }
          ForEach(rows) { choice in
            row(choice).id(choice.id)
          }
        }
        .listStyle(.inset)
        .clipShape(RoundedRectangle(cornerRadius: AIMTheme.radius))
        .contextMenu(forSelectionType: ProviderID.self) { _ in
        } primaryAction: { ids in
          // Double-click continues with the clicked provider.
          guard let id = ids.first, !model.isBusy,
                rows.first(where: { $0.id == id })?.available == true else { return }
          model.selectedProviderID = id
          onContinue()
        }
        .onChange(of: model.selectedProviderID) { _, id in proxy.scrollTo(id) }
      }
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
    .padding(AIMTheme.pageMargin)
    .frame(maxHeight: .infinity, alignment: .top)
    .onAppear {
      searchFocused = true
      keepSelectionVisible()
    }
    .onChange(of: query) { _, _ in keepSelectionVisible() }
    .task { await model.detectSignedInProviders() }
  }

  private var searchField: some View {
    TextField("Search providers", text: $query)
      .textFieldStyle(.plain)
      .aimFieldChrome(focused: searchFocused)
      .focused($searchFocused)
      .onSubmit(onContinueIfPossible)
      .onKeyPress(.downArrow) { move(1); return .handled }
      .onKeyPress(.upArrow) { move(-1); return .handled }
      .accessibilityLabel("Search providers")
      .overlay(alignment: .trailing) {
        if !query.isEmpty {
          Button { query = ""; searchFocused = true } label: {
            Image(systemName: "xmark.circle.fill")
          }
          .buttonStyle(.borderless)
          .padding(.trailing, AIMTheme.rowSpacing)
          .accessibilityLabel("Clear search")
        }
      }
  }

  private func row(_ choice: ProviderChoice) -> some View {
    let isSelected = model.selectedProviderID == choice.id
    return HStack(spacing: AIMTheme.rowSpacing) {
      ProviderMark(providerID: choice.id, size: 20)
      VStack(alignment: .leading, spacing: 0) {
        Text(choice.name).aimText(.body).lineLimit(1)
        Text(choice.subtitle).aimText(.secondary).lineLimit(1)
      }
      Spacer()
      if choice.signedInOnThisMac {
        Badge(text: ProviderChoices.signedInLabel)
      }
      if !choice.available {
        Badge(text: "WIP", tint: .secondary)
      }
    }
    .opacity(choice.available ? 1 : 0.64)
    .tag(choice.id)
    .selectionDisabled(!choice.available)
    .accessibilityLabel(choice.name)
    .accessibilityValue(
      [isSelected ? "Selected" : nil, choice.signedInOnThisMac ? ProviderChoices.signedInLabel : nil]
        .compactMap { $0 }.joined(separator: ", "))
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
    VStack(spacing: 0) {
      Form {
        Section("\(spec.name) credentials") {
          HStack(alignment: .top, spacing: AIMTheme.sectionSpacing) {
            ProviderMark(providerID: spec.id, size: 32)
            VStack(alignment: .leading, spacing: 2) {
              Text("Add a \(spec.name) account").aimText(.section)
              Text("Switch keeps these values in a private file on this Mac and uses them only to read usage.")
                .aimText(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
          ForEach(spec.fields, id: \.key) { field in
            fieldRow(field)
          }
        }
      }
      .formStyle(.grouped)

      ImportFooter(step: 2, labels: ["Provider", "Credentials", "Done"]) {
        AIMButton(title: "Back", disabled: model.isBusy, action: back)
      } trailing: {
        AIMButton(title: "Save", tone: .primary, disabled: !isComplete || model.isBusy, action: save)
          .keyboardShortcut(.defaultAction)
      }
      .padding(AIMTheme.pageMargin)
    }
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
    VStack(alignment: .leading, spacing: 2) {
      Group {
        if field.secure {
          SecureField(
            field.title, text: binding,
            prompt: Text(field.placeholder ?? "Paste the \(field.title.lowercased())"))
        } else {
          TextField(field.title, text: binding, prompt: Text(field.placeholder ?? ""))
        }
      }
      .privacySensitive(field.secure)
      .focused($focusedKey, equals: field.key)
      .onSubmit { if isComplete { save() } }
      .accessibilityLabel(field.optional ? "\(field.title), optional" : field.title)
      if field.optional {
        Text("Optional").aimText(.secondary)
      }
      if let name = prefilled[field.key] {
        Text("Filled from \(name) in this app's environment.").aimText(.secondary)
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
    return "Signed in as \(EmailPrivacy.display(identity.email ?? identity.key))"
  }

  var body: some View {
    VStack(spacing: 0) {
      Form {
        Section("\(spec.name) sign-in") {
          HStack(alignment: .top, spacing: AIMTheme.sectionSpacing) {
            ProviderMark(providerID: spec.id, size: 32)
            VStack(alignment: .leading, spacing: 2) {
              Text(signedInText)
                .aimText(.section)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
              Text(identity?.plan.map { "Plan: \($0.capitalized)" } ?? detailText)
                .aimText(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
          Notice(text: noticeText, tone: identity == nil && loaded ? AIMTheme.amber : AIMTheme.blue)
          if let file = spec.files.first {
            LabeledContent("Read from") {
              AIMCopyablePath(path: "~/" + file.path)
            }
          }
        }
      }
      .formStyle(.grouped)

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
      .padding(AIMTheme.pageMargin)
    }
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
