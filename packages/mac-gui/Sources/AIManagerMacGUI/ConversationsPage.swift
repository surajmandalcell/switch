import AIManagerCore
import AppKit
import SwiftUI

struct HistoryPage: View {
  @ObservedObject var model: AccountViewModel
  @State private var threadQuery: String

  init(model: AccountViewModel) {
    self.model = model
    _threadQuery = State(initialValue: UserDefaults.standard.string(forKey: ChatPlace.threadQueryKey) ?? "")
    ChatPlace.restoreThreadsScroll()
    _shown = State(initialValue: max(Self.pageSize, Int((AIMPlace.scroll["threads"] ?? 0) / Self.rowHeight) + 60))
  }

  // The list builds a page of rows at a time; building all 1000 rows cost about 100 ms per page switch.
  private static let pageSize = 100
  private static let rowHeight: CGFloat = 44
  @State private var shown: Int

  var body: some View {
    // Two cards: the thread list and the selected conversation.
    AIMFixedPage {
      HStack(spacing: 16) {
        AIMCard(
          title: "History", edges: .start, scrolls: true,
          accessory: { threadAccessory },
          content: { threadList.frame(maxHeight: .infinity) }
        )
        .frame(width: 300)
        AIMCard(edges: .end, scrolls: true) {
          ChatDetailPane(model: model)
            .id(model.selectedChatID)
            .frame(maxHeight: .infinity)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task { await model.refreshChatHistory(query: threadQuery) }
    .task(id: threadQuery) { await model.searchChatHistory(query: threadQuery) }
    .onChange(of: threadQuery) { _, query in
      shown = Self.pageSize
      UserDefaults.standard.set(query, forKey: ChatPlace.threadQueryKey)
    }
    .onDisappear { ChatPlace.saveThreadsScroll() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
      ChatPlace.saveThreadsScroll()
    }
  }

  /// The title row's trailing side: a warning button, an error dot, and the count.
  private var threadAccessory: some View {
    HStack(spacing: 6) {
      if model.chatHistory.skippedFileCount > 0 || model.chatHistory.unreadableRecordCount > 0 {
        WarningCopyButton(label: "Copy history warning") {
          model.copyWarnings([historyIssueText])
        }
        .help(historyIssueText)
      }
      if model.isChatHistoryLoading && model.chatHistory.threads.isEmpty {
        ProgressView().controlSize(.small)
      } else {
        if let error = model.chatHistoryError {
          Circle().fill(AIMTheme.red).frame(width: 6, height: 6)
            .help(error)
            .accessibilityLabel(error)
        }
        Text(historyCountText)
          .help(historyCountText)
          .aimText(.secondary)
          .monospacedDigit()
          .aimRolling(model.chatHistory.matchingThreadCount)
      }
    }
  }

  private var threadList: some View {
    VStack(spacing: 0) {
      HistorySearchField(text: $threadQuery, placeholder: "Search conversations")
        .environment(\.aimControlHeight, 32)
        .frame(maxWidth: .infinity)
        .aimBodyEdges()
        .padding(.horizontal, AIMTheme.cardInset)
        .padding(.bottom, AIMTheme.rowSpacing)

      if model.isChatHistoryLoading && model.chatHistory.threads.isEmpty {
        AIMLoadingRows(count: 8, rowHeight: Self.rowHeight)
          .frame(maxHeight: .infinity, alignment: .top)
      } else if model.chatHistory.threads.isEmpty {
        VStack(spacing: 4) {
          AIMIcon(name: .history).aimText(.section).foregroundStyle(.secondary)
          Text(threadQuery.isEmpty ? "No conversations yet" : "No matching conversations")
            .aimText(.body)
          Text(threadQuery.isEmpty ? "New Codex chats appear here." : "Try another word or thread ID.")
            .aimText(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        // A lazy column in the shared scroll view: a selected row is a fill, never an outline, and
        // the thin scroll bar sits in a fixed gutter at the trailing edge.
        AIMScrollView(name: "threads") {
          LazyVStack(spacing: 0) {
            ForEach(ChatThreadDayGroup.groups(Array(model.chatHistory.threads.prefix(shown)))) { group in
              Section {
                ForEach(group.threads) { thread in
                  ChatThreadButton(thread: thread, selected: thread.id == model.selectedChatID) {
                    Task { await model.selectChat(thread.id) }
                  }
                  .onAppear { if thread.id == model.chatHistory.threads.prefix(shown).last?.id { shown += Self.pageSize } }
                }
              } header: {
                Text(group.title)
                  .aimText(.secondary)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .padding(.horizontal, 6)
                  .padding(.vertical, 6)
                  .accessibilityAddTraits(.isHeader)
              }
            }
          }
          // The highlight sits as far from the card edge on the left as the gutter makes it on the right.
          .padding(.leading, AIMScroller.gutter)
          .padding(.trailing, AIMScroller.gutter)
          .padding(.bottom, AIMScroller.gutter)
        }
      }
    }
  }

  private var historyCountText: String {
    let result = model.chatHistory
    if threadQuery.isEmpty { return "\(result.totalThreadCount.formatted()) conversations" }
    return "\(result.matchingThreadCount.formatted()) of \(result.totalThreadCount.formatted()) conversations"
  }

  private var historyIssueText: String {
    let result = model.chatHistory
    var parts: [String] = []
    if result.skippedFileCount > 0 {
      parts.append(
        "\(result.skippedFileCount) transcript file\(result.skippedFileCount == 1 ? " was" : "s were") skipped")
    }
    if result.unreadableRecordCount > 0 {
      parts.append(
        "\(result.unreadableRecordCount) oversized or malformed record\(result.unreadableRecordCount == 1 ? " was" : "s were") skipped")
    }
    return parts.joined(separator: "; ") + "."
  }
}

extension ChatPlace {
  /// The thread list remembers its scroll offset in `AIMPlace.scroll`; this keeps it across launches.
  @MainActor static func restoreThreadsScroll() {
    guard AIMPlace.scroll["threads"] == nil,
      let saved = UserDefaults.standard.object(forKey: threadsScrollKey) as? Double else { return }
    AIMPlace.scroll["threads"] = CGFloat(saved)
  }

  @MainActor static func saveThreadsScroll() {
    guard let offset = AIMPlace.scroll["threads"] else { return }
    UserDefaults.standard.set(Double(offset), forKey: threadsScrollKey)
  }
}

private struct HistorySearchField: View {
  @Binding var text: String
  let placeholder: String
  var status: String? = nil
  var isLoading = false

  @FocusState private var focused: Bool

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass").aimFont(.body).foregroundStyle(.secondary)
        .accessibilityHidden(true)
      TextField(placeholder, text: $text)
        .textFieldStyle(.plain)
        .focused($focused)
      if isLoading {
        ProgressView().controlSize(.small)
      } else if let status {
        Text(status).aimText(.secondary).monospacedDigit().fixedSize()
      }
      if !text.isEmpty {
        Button { text = "" } label: { Image(systemName: "xmark.circle.fill").aimFont(.body) }
          .buttonStyle(.plain).foregroundStyle(.secondary)
          .help("Clear search")
          .accessibilityLabel("Clear search")
      }
    }
    .aimFieldChrome(focused: focused)
    .contentShape(Rectangle())
    .onTapGesture { focused = true }
  }
}

/// A thread row of the list: a fill when selected or focused with the keyboard, never an outline.
/// Hover and selection fade in and out.
private struct ChatThreadButton: View {
  let thread: ChatThreadSummary
  let selected: Bool
  let action: () -> Void
  @State private var hovered = false

  var body: some View {
    Button(action: action) {
      ChatThreadRow(thread: thread)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .frame(height: 44)
        .background(
          selected ? AIMTheme.rowHighlight : (hovered ? AIMTheme.tileFill : Color.clear),
          in: RoundedRectangle(cornerRadius: AIMTheme.tileRadius, style: .continuous))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .overlay(alignment: .bottom) { AIMHairline().padding(.horizontal, 6).opacity(0.45) }
    .onHover { hovered = $0 }
    .animation(AIMMotion.fade(AIMMotion.hover), value: hovered)
    .animation(AIMMotion.fade(AIMMotion.state), value: selected)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

struct ChatThreadRow: View {
  let thread: ChatThreadSummary

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(thread.title)
        .aimText(.body)
        .lineLimit(1)
        .truncationMode(.tail)
        .help(thread.title)
        .frame(maxWidth: .infinity, alignment: .leading)
      HStack(spacing: 6) {
        Text(thread.appSource.displayLabel)
          .help(thread.appSource.displayLabel)
          .aimText(.secondary)
        if let model = thread.model {
          Text("·").aimText(.secondary)
          Text(model).aimText(.secondary).truncationMode(.tail).help(model)
        }
        Spacer(minLength: 0)
        Text(thread.updatedAt.formatted(date: .omitted, time: .shortened))
          .aimText(.secondary).monospacedDigit().fixedSize()
      }
      .foregroundStyle(.secondary)
      .lineLimit(1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(thread.title), \(thread.appSource.displayLabel), \(subtitle)")
    .contextMenu { ChatTitleCopyButton(title: thread.title) }
  }

  private var subtitle: String {
    [thread.model, thread.updatedAt.formatted(date: .omitted, time: .shortened)]
      .compactMap { $0 }.joined(separator: " · ")
  }
}

enum ChatFilterPersistence {
  static let defaultsKey = "chat.messageFilterMask"

  static func load(from defaults: UserDefaults = .standard) -> ChatMessageFilter {
    guard defaults.object(forKey: defaultsKey) != nil else { return .all }
    return normalized(defaults.integer(forKey: defaultsKey))
  }

  static func save(_ filter: ChatMessageFilter, to defaults: UserDefaults = .standard) {
    defaults.set(normalized(filter.rawValue).rawValue, forKey: defaultsKey)
  }

  static func normalized(_ rawValue: Int) -> ChatMessageFilter {
    let filter = ChatMessageFilter(rawValue: rawValue & ChatMessageFilter.all.rawValue)
    return filter.isEmpty ? .all : filter
  }

  static func toggling(_ filter: ChatMessageFilter, in selection: ChatMessageFilter) -> ChatMessageFilter {
    let next = selection.symmetricDifference(filter)
    return next.isEmpty ? selection : next
  }
}

/// Message dates as "Oct 13, 12:56 PM", with the year only when it is not this year.
@MainActor private enum ChatDate {
  static func text(_ date: Date) -> String {
    let current = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
    return date.formatted(current ? .dateTime.month(.abbreviated).day().hour().minute()
      : .dateTime.month(.abbreviated).day().year().hour().minute())
  }
}

private struct ChatDetailPane: View {
  @ObservedObject var model: AccountViewModel
  @State private var messageQuery: String
  @State private var messageFilter: ChatMessageFilter
  @State private var isSearching = false
  @State private var searchGeneration = 0
  /// Where to scroll once the remembered message is loaded; cleared when the reader changes the search.
  @State private var restoreTarget: ChatScrollAnchor?
  /// Code blocks the reader opened, by message ID.
  @State private var expandedBlocks: [String: Set<Int>] = [:]
  /// Messages at this index and after were loaded by scrolling and fade in.
  @State private var fadeFrom = Int.max
  @State private var loadedCount = 0

  init(model: AccountViewModel) {
    self.model = model
    _messageQuery = State(initialValue: ChatPlace.messageQuery(for: model.selectedChatID))
    _messageFilter = State(initialValue: ChatFilterPersistence.load())
    _restoreTarget = State(initialValue: ChatPlace.anchor(for: model.selectedChatID))
    _expandedBlocks = State(initialValue: ChatPlace.blockStates(for: model.selectedChatID))
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      AIMHairline()
      searchBar
      AIMHairline()
      messages
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task(id: searchKey) { await updateMessageSearch() }
    .task(id: model.selectedChat?.messages.count ?? 0) { await loadUntilRestoreTarget() }
    .onChange(of: messageFilter.rawValue) { _, _ in
      ChatFilterPersistence.save(messageFilter)
      restoreTarget = nil
    }
    .onChange(of: messageQuery) { _, query in
      ChatPlace.saveMessageQuery(query, for: model.selectedChatID)
      restoreTarget = nil
    }
    .onChange(of: expandedBlocks) { _, states in
      ChatPlace.saveBlockStates(states, for: model.selectedChatID)
    }
    .onChange(of: model.selectedChat?.messages.count ?? 0) { old, new in
      // A page that arrives after the first fades in; a new search or chat does not.
      if old > 0, new > old { fadeFrom = old } else { fadeFrom = .max }
      loadedCount = new
    }
  }

  // MARK: Header

  /// The title has the whole row; the message count and token total sit on the subtitle line.
  @ViewBuilder private var header: some View {
    if let thread = selectedSummary {
      VStack(alignment: .leading, spacing: 2) {
        Text(thread.title).aimText(.section).lineLimit(1)
          .help(thread.title)
          .textSelection(.enabled)
          .contextMenu { ChatTitleCopyButton(title: thread.title) }
        HStack(spacing: AIMTheme.sectionSpacing) {
          Text(threadContext(thread)).lineLimit(1).help(threadContext(thread))
          Spacer(minLength: AIMTheme.rowSpacing)
          HStack(spacing: 6) {
            Text("\(thread.messageCount.formatted()) messages")
              .help("\(thread.messageCount.formatted()) messages")
            if let tokens = thread.totalTokens {
              Text("·")
              Text("\(tokens.formatted(.number.notation(.compactName))) tokens")
                .help("\(tokens.formatted()) recorded tokens")
            }
          }
          .monospacedDigit()
          .lineLimit(1)
          .fixedSize()
        }
        .aimText(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 12)
      .frame(height: 58)
    } else {
      Color.clear.frame(height: 58)
    }
  }

  private var searchBar: some View {
    VStack(spacing: 12) {
      HistorySearchField(text: $messageQuery, placeholder: "Search this chat",
        status: messageQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil
          : model.selectedChat.map { "\($0.matchingMessageCount.formatted()) matches" }, isLoading: isSearching)

      GeometryReader { geometry in
        let unit = max(0, geometry.size.width - 48) / 548
        HStack(spacing: 12) {
          ChatFilteredCopyButton(messages: model.selectedChat.map(displayedMessages) ?? [])
            .frame(width: 92 * unit)
          ForEach(ChatFilterChoice.allCases) { choice in
            ChatFilterButton(choice: choice, selected: messageFilter.contains(choice.filter)) {
                toggleFilter(choice.filter)
            }
            .frame(width: choice.widthWeight * unit)
          }
        }
      }
      .frame(height: 32)
    }
    .environment(\.aimControlHeight, 32)
    .padding(.horizontal, 12)
    .padding(.vertical, 12)
  }

  @ViewBuilder private var messages: some View {
    if model.selectedChat == nil && (model.isChatLoading || model.isChatHistoryLoading) {
      AIMLoadingRows(count: 5, rowHeight: 64)
        .frame(maxHeight: .infinity, alignment: .top)
    } else if let detail = model.selectedChat {
      // A new search or filter starts at the top of a fresh list.
      ChatMessageList(
        items: detailItems(detail), restore: restoreTarget,
        onReachEnd: { Task { await model.loadMoreChatMessages() } },
        onAnchor: { ChatPlace.saveAnchor($0, for: model.selectedChatID) },
        rowContent: { AnyView(detailRow($0)) }
      )
      .aimAppear()
      .id(listKey)
    } else {
      VStack(spacing: 4) {
        AIMIcon(name: .history).aimText(.section).foregroundStyle(.secondary)
        Text("Select a chat").aimText(.body)
        Text("Messages open here without changing the transcript.")
          .aimText(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  // MARK: Data

  private var selectedSummary: ChatThreadSummary? {
    model.selectedChat?.thread
      ?? model.chatHistory.threads.first { $0.id == model.selectedChatID }
  }

  private var searchKey: ChatMessageSearchKey {
    ChatMessageSearchKey(
      threadID: model.selectedChatID,
      query: messageQuery,
      filterMask: messageFilter.rawValue,
      fileByteCount: model.selectedChat?.thread.fileByteCount ?? 0)
  }

  private var listKey: String {
    "\(model.selectedChatID ?? "")|\(messageFilter.rawValue)|\(messageQuery.trimmingCharacters(in: .whitespacesAndNewlines))"
  }

  private func displayedMessages(_ detail: ChatThreadDetail) -> [ChatMessage] {
    detail.messages.filter { messageFilter.includes($0.role) }
  }

  private func toggleFilter(_ filter: ChatMessageFilter) {
    messageFilter = ChatFilterPersistence.toggling(filter, in: messageFilter)
  }

  private func detailItems(_ detail: ChatThreadDetail) -> [ChatRowItem] {
    var items: [ChatRowItem] = []
    let shown = displayedMessages(detail)
    if shown.isEmpty && !isSearching {
      let hasQuery = !messageQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      items.append(ChatRowItem(id: "empty", kind: .empty(hasQuery ? "No matching messages" : "No messages in this filter")))
    } else {
      for (index, message) in shown.enumerated() {
        let separated = index == 0 || shown[index - 1].role != message.role
        items.append(ChatRowItem(
          id: message.id,
          kind: .message(
            message, presentation: model.chatPresentations[message.id],
            expanded: expandedBlocks[message.id] ?? [], separated: separated),
          fadesIn: index >= fadeFrom))
      }
    }
    if detail.nextOffset != nil {
      items.append(ChatRowItem(id: "load-more", kind: .loadMore(loading: model.isChatPageLoading)))
    }
    items.append(ChatRowItem(id: "bottom", kind: .bottomSpace))
    return items
  }

  @ViewBuilder
  private func detailRow(_ item: ChatRowItem) -> some View {
    switch item.kind {
    case let .message(message, presentation, expanded, separated):
      ChatMessageRow(
        message: message, presentation: presentation, separated: separated,
        expanded: expanded, fadesIn: item.fadesIn,
        toggleBlock: { block in
          var next = expandedBlocks[message.id] ?? []
          if !next.insert(block).inserted { next.remove(block) }
          expandedBlocks[message.id] = next
        })
    case let .empty(text):
      VStack(spacing: 6) {
        AIMIcon(name: .search).aimText(.section).foregroundStyle(.secondary)
        Text(text).aimText(.body)
      }
      .frame(maxWidth: .infinity, minHeight: 120)
      .padding(.horizontal, 12)
    case .bottomSpace:
      Color.clear.frame(height: 12)
    case let .loadMore(loading):
      HStack(spacing: 6) {
        if loading { ProgressView().controlSize(.mini) }
        AIMButton(title: loading ? "Loading messages" : "Load more messages",
          disabled: loading) { Task { await model.loadMoreChatMessages() } }
      }
      .frame(maxWidth: .infinity, minHeight: 32)
    }
  }

  private func threadContext(_ thread: ChatThreadSummary) -> String {
    var parts: [String] = [thread.appSource.displayLabel]
    if let directory = thread.workingDirectory {
      let project = URL(fileURLWithPath: directory).lastPathComponent
      if !project.isEmpty { parts.append(project) }
    }
    if let model = thread.model { parts.append(model) }
    parts.append(thread.updatedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
    if thread.archived { parts.append("Archived") }
    return parts.joined(separator: " · ")
  }

  /// Loads pages until the remembered message is in the list, then the list scrolls to it.
  @MainActor
  private func loadUntilRestoreTarget() async {
    guard let target = restoreTarget, let detail = model.selectedChat else { return }
    if detail.messages.contains(where: { $0.id == target.messageID }) { return }
    if detail.nextOffset == nil { restoreTarget = nil; return }
    await model.loadMoreChatMessages()
  }

  @MainActor
  private func updateMessageSearch() async {
    searchGeneration += 1
    let generation = searchGeneration
    defer { if searchGeneration == generation { isSearching = false } }
    guard model.selectedChat != nil else {
      return
    }
    #if AI_MANAGER_PREVIEW
    let threadID = model.selectedChatID ?? ""
    ChatReaderReadiness.activeSearches[threadID, default: 0] += 1
    defer {
      let remaining = ChatReaderReadiness.activeSearches[threadID, default: 1] - 1
      ChatReaderReadiness.activeSearches[threadID] = remaining > 0 ? remaining : nil
    }
    #endif
    isSearching = true
    do {
      try await Task.sleep(for: .milliseconds(120))
      await model.searchChatMessages(query: messageQuery, filter: messageFilter)
      guard !Task.isCancelled else { return }
    } catch is CancellationError {
      return
    } catch {
      return
    }
  }
}

#if AI_MANAGER_PREVIEW
@MainActor enum ChatReaderReadiness {
  static var activeSearches: [String: Int] = [:]
}
#endif

private struct ChatMessageSearchKey: Hashable {
  let threadID: String?
  let query: String
  let filterMask: Int
  let fileByteCount: Int64
}

private enum ChatFilterChoice: String, CaseIterable, Identifiable {
  case prompts = "Prompts"
  case responses = "Responses"
  case tools = "Tools"
  case other = "Other"

  var id: String { rawValue }

  var filter: ChatMessageFilter {
    switch self {
    case .prompts: .prompts
    case .responses: .responses
    case .tools: .tools
    case .other: .other
    }
  }

  var symbol: String {
    switch self {
    case .prompts: "curlybraces"
    case .responses: "bubble.right"
    case .tools: "wrench.and.screwdriver"
    case .other: "square.3.layers.3d"
    }
  }

  var widthWeight: CGFloat {
    switch self {
    case .prompts: 110
    case .responses: 126
    case .tools: 98
    case .other: 122
    }
  }
}

private struct ChatFilterButton: View {
  let choice: ChatFilterChoice
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label(choice.rawValue, systemImage: choice.symbol).frame(maxWidth: .infinity)
    }
      .buttonStyle(ChatToolbarButtonStyle(selected: selected))
      .accessibilityAddTraits(selected ? .isSelected : [])
      .accessibilityValue(selected ? "Shown" : "Hidden")
      .accessibilityLabel("Show \(choice.rawValue.lowercased())")
  }
}

struct ChatFilteredCopyButton: View {
  let messages: [ChatMessage]
  @State private var copied = false

  var body: some View {
    Button {
      let text = ChatTranscriptExport.text(for: messages)
      ChatPasteboard.copy(text)
      withAnimation(AIMMotion.fade(AIMMotion.state)) { copied = true }
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(1.2))
        withAnimation(AIMMotion.fade(AIMMotion.state)) { copied = false }
      }
    } label: {
      Label("Copy",
        systemImage: copied ? AIMIcon.Name.check.symbol : AIMIcon.Name.copy.symbol)
        .contentTransition(.opacity)
        .frame(maxWidth: .infinity)
    }
    .buttonStyle(ChatToolbarButtonStyle())
    .disabled(messages.isEmpty)
    .help("Copy the visible messages")
    .accessibilityLabel(copied ? "Copied" : "Copy")
  }
}

private struct ChatToolbarButtonStyle: ButtonStyle {
  var selected = true

  func makeBody(configuration: Configuration) -> some View {
    ChatToolbarButtonFace(configuration: configuration, selected: selected)
  }
}

private struct ChatToolbarButtonFace: View {
  let configuration: ButtonStyleConfiguration
  let selected: Bool
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.isFocused) private var focused
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hovered = false

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 6)
    let fill = configuration.isPressed ? AIMTheme.controlPressed
      : hovered && isEnabled ? AIMTheme.rowHover : Color.primary.opacity(selected ? 0.045 : 0)
    configuration.label
      .labelStyle(AIMButtonLabelStyle())
      .aimFont(.body)
      .foregroundStyle(Color.primary.opacity(isEnabled ? 1 : 0.45))
      .lineLimit(1)
      .padding(.horizontal, 10)
      .frame(height: 32)
      .background(shape.fill(fill))
      .aimBorder(Color.primary.opacity(isEnabled ? (selected ? 0.22 : 0.12) : 0.08), in: shape)
      .overlay(shape.fill(focused && isEnabled ? AIMTheme.focusTint : Color.clear))
      .contentShape(shape)
      .uiLint(.control)
      .onHover { hovered = $0 }
      .scaleEffect(AIMMotion.scale(pressed: configuration.isPressed && isEnabled, reduceMotion: reduceMotion))
      .animation(AIMMotion.fade(AIMMotion.hover), value: hovered)
      .animation(AIMMotion.fade(AIMMotion.hover), value: configuration.isPressed)
      .animation(AIMMotion.fade(AIMMotion.state), value: selected)
  }
}

private struct ChatTitleCopyButton: View {
  let title: String

  var body: some View {
    Button("Copy title") {
      ChatPasteboard.copy(title)
    }
  }
}

// MARK: - Messages

/// One message: a role/date strip above its Markdown sections.
/// Every role shares the leading edge. The row is as tall as its content, so nothing clips.
private struct ChatMessageRow: View {
  let message: ChatMessage
  let presentation: ChatMessagePresentation?
  let separated: Bool
  let expanded: Set<Int>
  let fadesIn: Bool
  let toggleBlock: (Int) -> Void
  @State private var shown: Bool

  init(
    message: ChatMessage, presentation: ChatMessagePresentation?, separated: Bool, expanded: Set<Int>,
    fadesIn: Bool, toggleBlock: @escaping (Int) -> Void
  ) {
    self.message = message
    self.presentation = presentation
    self.separated = separated
    self.expanded = expanded
    self.fadesIn = fadesIn
    self.toggleBlock = toggleBlock
    // A message loaded by scrolling fades in once; a recycled row never replays it.
    _shown = State(initialValue: !(fadesIn && AIMMotion.isLive && !ChatFadeLedger.played(message.id)))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Color.primary.opacity(0.02), in: RoundedRectangle(cornerRadius: AIMTheme.radius))
        .aimBorder(AIMTheme.line, in: RoundedRectangle(cornerRadius: AIMTheme.radius))
      ChatMessageBlocks(message: message, presentation: presentation, expanded: expanded, toggleBlock: toggleBlock)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .frame(maxWidth: 820, alignment: .leading)
    // The right side gives the scroll bar gutter back, keeping the reader's 12 pt insets equal.
    .padding(.leading, 12)
    .padding(.trailing, 12 - AIMScroller.gutter)
    .padding(.top, separated ? 12 : 4)
    .padding(.bottom, 4)
    .frame(maxWidth: .infinity, alignment: .leading)
    .opacity(shown ? 1 : AIMMotion.appearOpacity)
    .onAppear {
      guard !shown else { return }
      ChatFadeLedger.mark(message.id)
      withAnimation(AIMMotion.fade(AIMMotion.appear)) { shown = true }
    }
  }

  /// Role, model, and date on their own line. The model is the first to truncate on a narrow window.
  private var header: some View {
    HStack(spacing: 6) {
      Text(message.role.displayName)
        .aimText(.section, tint: .primary)
        .fixedSize()
      if message.role == .assistant, let model = message.model {
        Text("·")
        Text(model).lineLimit(1).truncationMode(.tail).layoutPriority(-1).help(model)
      }
      if let timestamp = message.timestamp {
        Text(ChatDate.text(timestamp)).monospacedDigit().lineLimit(1).fixedSize().padding(.leading, 24)
          .help(ChatDate.text(timestamp))
      }
      Spacer(minLength: 6)
      ChatCopyButton(text: message.text, label: "Copy message", emphasized: true)
    }
    .aimText(.secondary)
    .frame(height: 20)
  }

}

/// Messages that were already announced as new, so a recycled row does not fade in again.
@MainActor private enum ChatFadeLedger {
  private static var shown = Set<String>()

  static func played(_ id: String) -> Bool { shown.contains(id) }
  static func mark(_ id: String) { shown.insert(id) }
}

private struct ChatMessageBlocks: View {
  let message: ChatMessage
  let presentation: ChatMessagePresentation?
  let expanded: Set<Int>
  let toggleBlock: (Int) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let presentation {
        ForEach(presentation.sections) { section in
          ChatMessageSection(section: section, bare: message.role == .tool, expanded: expanded, toggle: toggleBlock)
        }
        if presentation.sourceWasTruncated {
          Text("This long message is shortened in the reader.")
            .aimText(.secondary, tint: AIMTheme.amber)
        }
      } else {
        Text(message.text)
          .aimText(.body)
          .lineSpacing(4)
          .textSelection(.enabled)
          .padding(12)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct ChatMessageSection: View {
  let section: ChatPresentationSection
  let bare: Bool
  let expanded: Set<Int>
  let toggle: (Int) -> Void

  private var collapsed: Bool { section.isCollapsible && expanded.contains(section.id) }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let heading = section.heading, case let .heading(_, _, text) = heading {
        if section.isCollapsible {
          Button { toggle(section.id) } label: {
            headingRow(text)
          }
          .buttonStyle(.plain)
          .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
        } else {
          headingRow(text)
        }
        if !collapsed { AIMHairline().padding(.horizontal, 12) }
      }
      if !collapsed {
        VStack(alignment: .leading, spacing: 10) {
          ForEach(section.blocks) { block in
            ChatPresentationBlockView(block: block, bare: bare,
              expanded: expanded.contains(block.id), toggle: { toggle(block.id) })
          }
        }
        .padding(12)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.primary.opacity(0.02), in: RoundedRectangle(cornerRadius: AIMTheme.radius))
    .aimBorder(AIMTheme.line, in: RoundedRectangle(cornerRadius: AIMTheme.radius))
  }

  private func headingRow(_ text: AttributedString) -> some View {
    HStack(spacing: 10) {
      Image(systemName: symbol).aimFont(.body).accessibilityHidden(true)
      Text(text).aimText(.section)
      Spacer(minLength: 4)
      if section.isCollapsible {
        Image(systemName: collapsed ? "chevron.right" : "chevron.down").aimFont(.secondary).accessibilityHidden(true)
      }
    }
    .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
    .padding(.horizontal, 12)
    .contentShape(Rectangle())
    .accessibilityAddTraits(.isHeader)
  }

  private var symbol: String {
    if let heading = section.heading, case let .heading(_, _, text) = heading {
      let title = String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      if title == "goal" || title.hasPrefix("goal ") || title.hasPrefix("goal:") { return "clipboard" }
      if title.hasPrefix("repository") { return "folder" }
      if title.hasPrefix("inputs") { return "shippingbox" }
      if title.hasPrefix("rules") || title.hasPrefix("hard rules") { return "exclamationmark.triangle" }
      if title.hasPrefix("steps") { return "list.number" }
    }
    if section.blocks.contains(where: { if case .table = $0 { true } else { false } }) { return "tablecells" }
    if section.blocks.contains(where: { if case .orderedList = $0 { true } else { false } }) { return "list.number" }
    if section.blocks.contains(where: { if case .unorderedList = $0 { true } else { false } }) { return "list.bullet" }
    return "doc.text"
  }
}

struct ChatPresentationBlockView: View {
  let block: ChatPresentationBlock
  let bare: Bool
  let expanded: Bool
  let toggle: () -> Void

  @ViewBuilder var body: some View {
    switch block {
    case let .paragraph(_, text):
      readable(text)
    case let .heading(_, _, text):
      // Markdown heading levels all read in the Section role.
      Text(text)
        .aimText(.section)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    case let .quote(_, text):
      HStack(alignment: .top, spacing: 9) {
        Rectangle().fill(AIMTheme.line).frame(width: 2)
        readable(text).foregroundStyle(.secondary)
      }
    case let .unorderedList(_, items):
      VStack(alignment: .leading, spacing: 5) {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
          HStack(alignment: .firstTextBaseline, spacing: AIMTheme.rowSpacing) {
            Text("•").aimText(.body)
            readable(item)
          }
        }
      }
    case let .orderedList(_, items):
      VStack(alignment: .leading, spacing: 5) {
        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
          HStack(alignment: .firstTextBaseline, spacing: AIMTheme.rowSpacing) {
            Text("\(index + 1).")
              .aimText(.body).monospacedDigit()
              .frame(width: 24, height: 24)
              .background(AIMTheme.tileFill, in: RoundedRectangle(cornerRadius: 4))
            readable(item)
          }
        }
      }
    case let .code(_, language, preview, expandedText, sourceWasTruncated):
      ChatCodeBlock(
        language: language, preview: preview, expandedText: expandedText,
        sourceWasTruncated: sourceWasTruncated, expanded: expanded, bare: bare, toggle: toggle)
    case let .table(_, headers, rows):
      Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 0) {
        GridRow {
          ForEach(headers.indices, id: \.self) { column in
            Text(headers[column]).aimText(headers.count == 2 && column > 0 ? .body : .section)
              .fixedSize(horizontal: false, vertical: true)
              .frame(width: headers.count == 2 && column == 0 ? 128 : nil, alignment: .leading)
              .padding(.vertical, 6)
          }
        }
        ForEach(rows.indices, id: \.self) { row in
          AIMHairline().gridCellColumns(headers.count)
          GridRow(alignment: .top) {
            ForEach(headers.indices, id: \.self) { column in
              Text(rows[row][column]).aimText(headers.count == 2 && column == 0 ? .section : .body)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: headers.count == 2 && column == 0 ? 128 : nil, alignment: .leading)
                .frame(maxWidth: headers.count == 2 && column == 0 ? nil : .infinity, alignment: .leading)
                .padding(.vertical, 6)
            }
          }
        }
      }
      .textSelection(.enabled)
      .overlay(alignment: .leading) {
        if headers.count == 2 {
          Rectangle().fill(AIMTheme.line.opacity(0.6)).frame(width: 1).offset(x: 134).allowsHitTesting(false)
        }
      }
    case .divider:
      AIMHairline().padding(.vertical, 2)
    }
  }

  private func readable(_ text: AttributedString) -> some View {
    Text(text)
      .aimText(.body)
      .lineSpacing(4)
      .textSelection(.enabled)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A code block wraps long lines, so the conversation scrolls vertically through it and no inner
/// scroll view captures the wheel. It shows every line up to the presenter's bound; past it, an
/// explicit button shows the rest. `bare` is tool output on the message's own surface.
struct ChatCodeBlock: View {
  let language: String?
  let preview: String
  let expandedText: String?
  let sourceWasTruncated: Bool
  var expanded = false
  var bare = false
  var toggle: (() -> Void)?

  private var visibleText: String { expanded ? (expandedText ?? preview) : preview }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if !bare {
        HStack(spacing: AIMTheme.rowSpacing) {
          Text(language?.uppercased() ?? "CODE")
            .aimText(.secondary, monospaced: true)
          Spacer()
          ChatCopyButton(text: expandedText ?? preview, label: "Copy code", emphasized: true)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(AIMTheme.chatOtherSurface)
      }

      Text(visibleText)
        .aimText(.secondary, monospaced: true, tint: .primary)
        .lineSpacing(3)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(bare ? 0 : 12)

      if let expandedText, let toggle {
        Button(action: toggle) {
          Text(expanded ? "Show fewer lines" : "Show all \(lineCount(expandedText).formatted()) lines")
            .aimFont(.body).foregroundStyle(AIMTheme.linkColor)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, bare ? 0 : 12)
        .padding(.bottom, bare ? 0 : 10)
        .padding(.top, bare ? 6 : 0)
      } else if sourceWasTruncated {
        Text("Code shortened")
          .aimText(.secondary, tint: AIMTheme.amber)
          .padding(.horizontal, bare ? 0 : 12)
          .padding(.bottom, bare ? 0 : 10)
      }
    }
    .background(bare ? Color.clear : AIMTheme.chatCodeSurface)
    .clipShape(RoundedRectangle(cornerRadius: AIMTheme.tileRadius, style: .continuous))
  }

  private func lineCount(_ text: String) -> Int {
    text.utf8.reduce(1) { $1 == 10 ? $0 + 1 : $0 }
  }
}

private struct ChatCopyButton: View {
  let text: String
  let label: String
  let emphasized: Bool
  @State private var copied = false

  var body: some View {
    Button {
      ChatPasteboard.copy(text)
      withAnimation(AIMMotion.fade(AIMMotion.state)) { copied = true }
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(1.2))
        withAnimation(AIMMotion.fade(AIMMotion.state)) { copied = false }
      }
    } label: {
      // The check fades in over the copy glyph in place, so the button never changes size.
      ZStack {
        AIMIcon(name: .copy).opacity(copied ? 0 : 1)
        AIMIcon(name: .check).opacity(copied ? 1 : 0)
      }
      .aimFont(.secondary)
      .frame(width: 20, height: 20)
      .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .foregroundStyle(copied ? AIMTheme.green : Color.secondary)
    .opacity(emphasized || copied ? 1 : 0.4)
    .animation(AIMMotion.fade(AIMMotion.hover), value: emphasized)
    .help(copied ? "Copied" : label)
    .accessibilityLabel(copied ? "Copied" : label)
  }
}

@MainActor enum ChatPasteboard {
  #if AI_MANAGER_PREVIEW
  static var previewName: NSPasteboard.Name?
  #endif

  static func copy(_ text: String) {
    #if AI_MANAGER_PREVIEW
    guard let previewName else { return }
    let pasteboard = NSPasteboard(name: previewName)
    #else
    let pasteboard = NSPasteboard.general
    #endif
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }
}
