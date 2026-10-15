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
      HStack(spacing: AIMTheme.cardGap) {
        AIMCard(
          title: "Conversations", edges: .start, scrolls: true,
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
          .aimText(.secondary)
          .monospacedDigit()
          .aimRolling(model.chatHistory.matchingThreadCount)
      }
    }
  }

  private var threadList: some View {
    VStack(spacing: 0) {
      HistorySearchField(text: $threadQuery, placeholder: "Search conversations")
        .frame(maxWidth: .infinity)
        .aimBodyEdges()
        .padding(.horizontal, AIMTheme.cardInset)
        .padding(.bottom, AIMTheme.rowSpacing)

      if model.isChatHistoryLoading && model.chatHistory.threads.isEmpty {
        VStack(spacing: AIMTheme.rowSpacing) {
          ProgressView().controlSize(.small)
          Text("Reading chat library").aimText(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

  @FocusState private var focused: Bool

  var body: some View {
    HStack(spacing: 6) {
      TextField(placeholder, text: $text)
        .textFieldStyle(.plain)
        .focused($focused)
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
        .frame(maxWidth: .infinity, alignment: .leading)
      HStack(spacing: 0) {
        Text(thread.appSource.displayLabel)
          .aimText(.secondary)
          .padding(.horizontal, 4)
          .frame(height: 16)
          .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
          .fixedSize(horizontal: true, vertical: false)
        Text(" · " + subtitle)
          .aimText(.secondary)
          .truncationMode(.tail)
      }
      .foregroundStyle(.secondary)
      .lineLimit(1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(thread.title), \(thread.appSource.displayLabel), \(subtitle)")
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
    ChatMessageFilter(rawValue: rawValue & ChatMessageFilter.all.rawValue)
  }
}

/// Message dates as "Oct 13, 12:56 PM", with the year only when it is not this year.
@MainActor private enum ChatDate {
  private static let sameYear: DateFormatter = make("MMMdjmm")
  private static let otherYear: DateFormatter = make("MMMdyjmm")

  private static func make(_ template: String) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate(template)
    return formatter
  }

  static func text(_ date: Date) -> String {
    let current = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
    return (current ? sameYear : otherYear).string(from: date)
  }
}

private struct ChatDetailPane: View {
  @ObservedObject var model: AccountViewModel
  @State private var messageQuery: String
  @State private var messageFilter: ChatMessageFilter
  @State private var isSearching = false
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
        HStack(spacing: AIMTheme.sectionSpacing) {
          Text(threadContext(thread)).lineLimit(1)
          Spacer(minLength: AIMTheme.rowSpacing)
          HStack(spacing: 6) {
            Text("\(thread.messageCount.formatted()) messages")
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
      .padding(.horizontal, AIMTheme.sectionSpacing)
      .frame(height: 58)
    } else {
      Color.clear.frame(height: 58)
    }
  }

  private var searchBar: some View {
    VStack(spacing: AIMTheme.rowSpacing) {
      HStack(spacing: AIMTheme.rowSpacing) {
        HistorySearchField(text: $messageQuery, placeholder: "Search this chat")
        if isSearching {
          ProgressView().controlSize(.small)
        } else if let detail = model.selectedChat, messageFilter != .all || !messageQuery.isEmpty {
          Text(messageCountText(detail))
            .aimText(.secondary)
            .monospacedDigit()
            .aimRolling(detail.matchingMessageCount)
        }
        if let detail = model.selectedChat {
          ChatFilteredCopyButton(messages: displayedMessages(detail))
        }
      }

      HStack(spacing: AIMTheme.rowSpacing) {
        Text("Show").aimText(.secondary)
        ForEach(ChatFilterChoice.allCases) { choice in
          ChatFilterButton(
            choice: choice,
            selected: messageFilter.contains(choice.filter)) {
              toggleFilter(choice.filter)
            }
        }
        Spacer(minLength: 0)
      }
    }
    .padding(.horizontal, AIMTheme.sectionSpacing)
    .padding(.vertical, AIMTheme.rowSpacing)
  }

  @ViewBuilder private var messages: some View {
    if model.isChatLoading {
      VStack(spacing: AIMTheme.rowSpacing) {
        ProgressView().controlSize(.small)
        Text("Opening chat").aimText(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    if messageFilter.contains(filter) {
      messageFilter.remove(filter)
    } else {
      messageFilter.insert(filter)
    }
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

  private func messageCountText(_ detail: ChatThreadDetail) -> String {
    if messageQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let count = detail.matchingMessageCount
      return messageFilter == .all
        ? "\(count.formatted()) messages"
        : "\(count.formatted()) shown"
    }
    return "\(detail.matchingMessageCount.formatted()) matches"
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
    guard model.selectedChat != nil else {
      isSearching = false
      return
    }
    isSearching = true
    do {
      try await Task.sleep(for: .milliseconds(120))
      await model.searchChatMessages(query: messageQuery, filter: messageFilter)
      guard !Task.isCancelled else { return }
      isSearching = false
    } catch is CancellationError {
      return
    } catch {
      isSearching = false
    }
  }
}

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
}

private struct ChatFilterButton: View {
  let choice: ChatFilterChoice
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Toggle(choice.rawValue, isOn: Binding(get: { selected }, set: { _ in action() }))
      .toggleStyle(AIMChipToggleStyle())
      .accessibilityLabel("Show \(choice.rawValue.lowercased())")
  }
}

private struct ChatFilteredCopyButton: View {
  let messages: [ChatMessage]
  @State private var copied = false

  var body: some View {
    Button {
      let text = ChatTranscriptExport.text(for: messages)
      #if !AI_MANAGER_PREVIEW
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
      #endif
      withAnimation(AIMMotion.fade(AIMMotion.state)) { copied = true }
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(1.2))
        withAnimation(AIMMotion.fade(AIMMotion.state)) { copied = false }
      }
    } label: {
      Label(copied ? "Copied" : "Copy shown",
        systemImage: copied ? AIMIcon.Name.check.symbol : AIMIcon.Name.copy.symbol)
        .contentTransition(.opacity)
    }
    // The shared 28 pt push button: even side padding and a 6 pt icon-to-label gap.
    .buttonStyle(AIMPushButtonStyle())
    .disabled(messages.isEmpty)
    .help("Copy the messages currently shown")
    .accessibilityLabel(copied ? "Copied" : "Copy shown messages")
  }
}

// MARK: - Messages

/// One message: a filled surface with a header line (role, model, date, copy) above the content.
/// Every role shares the leading edge. The row is as tall as its content, so nothing clips.
private struct ChatMessageRow: View {
  let message: ChatMessage
  let presentation: ChatMessagePresentation?
  let separated: Bool
  let expanded: Set<Int>
  let fadesIn: Bool
  let toggleBlock: (Int) -> Void
  @State private var hovered = false
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
    VStack(alignment: .leading, spacing: AIMTheme.rowSpacing) {
      header
      ChatMessageBlocks(message: message, presentation: presentation, expanded: expanded, toggleBlock: toggleBlock)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(messageSurface, in: RoundedRectangle(cornerRadius: AIMTheme.radius, style: .continuous))
    .frame(maxWidth: 820, alignment: .leading)
    // The right side gives the scroll bar gutter back, so a surface ends on the card's 16 pt inset.
    .padding(.leading, AIMTheme.sectionSpacing)
    .padding(.trailing, AIMTheme.sectionSpacing - AIMScroller.gutter)
    .padding(.top, separated ? 12 : 4)
    .padding(.bottom, 4)
    .frame(maxWidth: .infinity, alignment: .leading)
    .opacity(shown ? 1 : AIMMotion.appearOpacity)
    .onHover { hovered = $0 }
    .animation(AIMMotion.fade(AIMMotion.hover), value: hovered)
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
        .aimText(.secondary, tint: .primary)
        .fixedSize()
      if message.role == .assistant, let model = message.model {
        Text("·")
        Text(model).lineLimit(1).truncationMode(.tail).layoutPriority(-1)
      }
      if let timestamp = message.timestamp {
        Text("·")
        Text(ChatDate.text(timestamp)).monospacedDigit().lineLimit(1).fixedSize()
      }
      Spacer(minLength: 6)
      ChatCopyButton(text: message.text, label: "Copy message", emphasized: hovered)
    }
    .aimText(.secondary)
    .frame(height: 20)
  }

  private var messageSurface: Color {
    switch message.role {
    case .user: AIMTheme.chatUserSurface
    case .assistant: AIMTheme.chatAssistantSurface
    case .tool: AIMTheme.chatCodeSurface
    case .other: AIMTheme.chatOtherSurface
    }
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
        ForEach(presentation.blocks) { block in
          ChatPresentationBlockView(
            block: block, bare: message.role == .tool,
            expanded: expanded.contains(block.id), toggle: { toggleBlock(block.id) })
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
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct ChatPresentationBlockView: View {
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
              .frame(width: 24, alignment: .trailing)
            readable(item)
          }
        }
      }
    case let .code(_, language, preview, expandedText, sourceWasTruncated):
      ChatCodeBlock(
        language: language, preview: preview, expandedText: expandedText,
        sourceWasTruncated: sourceWasTruncated, expanded: expanded, bare: bare, toggle: toggle)
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
      #if !AI_MANAGER_PREVIEW
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
      #endif
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
