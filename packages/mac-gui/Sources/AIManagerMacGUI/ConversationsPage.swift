import AIManagerCore
import AppKit
import SwiftUI

struct HistoryPage: View {
  @ObservedObject var model: AccountViewModel
  @State private var threadQuery = ""

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
          .contentTransition(.numericText())
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
            ForEach(model.chatHistory.threads) { thread in
              ChatThreadButton(thread: thread, selected: thread.id == model.selectedChatID) {
                Task { await model.selectChat(thread.id) }
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
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

private struct ChatThreadRow: View {
  let thread: ChatThreadSummary

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(thread.title)
        .aimText(.body)
        .lineLimit(1)
      Text(projectLabel)
        .aimText(.secondary)
        .lineLimit(1)
    }
    .accessibilityLabel("\(thread.title), \(projectLabel)")
  }

  private var projectLabel: String {
    guard let directory = thread.workingDirectory else { return "Codex" }
    let name = URL(fileURLWithPath: directory).lastPathComponent
    return name.isEmpty ? "Codex" : name
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

private struct ChatDetailPane: View {
  @ObservedObject var model: AccountViewModel
  @State private var messageQuery = ""
  @State private var messageFilter: ChatMessageFilter
  @State private var isSearching = false
  @State private var presentations: [String: ChatMessagePresentation] = [:]
  @State private var presentationRevision = 0
  /// Long messages the reader opened with Show more.
  @State private var expandedMessages: Set<String> = []

  init(model: AccountViewModel) {
    self.model = model
    _messageFilter = State(initialValue: ChatFilterPersistence.load())
  }

  var body: some View {
    VStack(spacing: 0) {
      if let thread = selectedSummary {
        HStack(alignment: .bottom, spacing: AIMTheme.sectionSpacing) {
          VStack(alignment: .leading, spacing: 2) {
            Text(thread.title).aimText(.section).lineLimit(1)
            Text(threadContext(thread)).aimText(.secondary).lineLimit(1)
          }
          Spacer(minLength: AIMTheme.rowSpacing)
          HStack(spacing: 6) {
            Text("\(thread.messageCount.formatted()) messages")
            if let tokens = thread.totalTokens {
              Text("·")
              Text("\(tokens.formatted(.number.notation(.compactName))) tokens")
                .help("\(tokens.formatted()) recorded tokens")
            }
          }
          .aimText(.secondary)
          .monospacedDigit()
          .lineLimit(1)
        }
        .padding(.horizontal, AIMTheme.sectionSpacing)
        .padding(.vertical, AIMTheme.rowSpacing)
        .frame(height: 58)
      } else {
        Color.clear.frame(height: 58)
      }
      AIMHairline()

      VStack(spacing: AIMTheme.rowSpacing) {
        HStack(spacing: AIMTheme.rowSpacing) {
          HistorySearchField(text: $messageQuery, placeholder: "Search this chat")
          if isSearching {
            ProgressView().controlSize(.small)
          } else if let detail = model.selectedChat, messageFilter != .all || !messageQuery.isEmpty {
            Text(messageCountText(detail))
              .aimText(.secondary)
              .monospacedDigit()
              .contentTransition(.numericText())
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
      AIMHairline()

      if model.isChatLoading {
        VStack(spacing: AIMTheme.rowSpacing) {
          ProgressView().controlSize(.small)
          Text("Opening chat").aimText(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let detail = model.selectedChat {
        AIMVirtualList(
          items: detailItems(detail), rowSpacing: 0,
          contentRevision: presentationRevision,
          restoreKey: "messages-\(model.selectedChatID ?? "")",
          onReachEnd: { Task { await model.loadMoreChatMessages() } }
        ) { item in
          AnyView(detailRow(item))
        }
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
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task(id: searchKey) { await updateMessageSearch() }
    .task(id: presentationKey) { await updatePresentations() }
    .onChange(of: messageFilter.rawValue) { _, _ in
      ChatFilterPersistence.save(messageFilter)
    }
  }

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

  private var presentationKey: ChatPresentationKey {
    ChatPresentationKey(
      threadID: model.selectedChatID,
      fileByteCount: model.selectedChat?.thread.fileByteCount ?? 0,
      messageIDs: model.selectedChat?.messages.map(\.id) ?? [])
  }

  private func displayedMessages(_ detail: ChatThreadDetail) -> [ChatMessage] {
    filteredMessages(detail.messages)
  }

  private func filteredMessages(_ messages: [ChatMessage]) -> [ChatMessage] {
    messages.filter { messageFilter.includes($0.role) }
  }

  private func toggleFilter(_ filter: ChatMessageFilter) {
    if messageFilter.contains(filter) {
      messageFilter.remove(filter)
    } else {
      messageFilter.insert(filter)
    }
  }

  private func detailItems(_ detail: ChatThreadDetail) -> [ChatDetailListItem] {
    var items: [ChatDetailListItem] = []
    let messages = displayedMessages(detail)
    if messages.isEmpty && !isSearching {
      let hasQuery = !messageQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      items.append(.empty(hasQuery ? "No matching messages" : "No messages in this filter"))
    } else {
      items.append(contentsOf: messages.enumerated().map { index, message in
        .message(
          message,
          separated: index == 0 || messages[index - 1].role != message.role)
      })
    }
    if detail.nextOffset != nil { items.append(.loadMore) }
    items.append(.bottomSpace)
    return items
  }

  @ViewBuilder
  private func detailRow(_ item: ChatDetailListItem) -> some View {
    switch item {
    case let .message(message, separated):
      ChatMessageRow(
        message: message,
        presentation: presentations[message.id],
        fallbackText: model.renderedChatMessages[message.id] ?? AttributedString(message.text),
        separated: separated,
        expanded: expandedMessages.contains(message.id),
        toggleExpanded: {
          if !expandedMessages.insert(message.id).inserted { expandedMessages.remove(message.id) }
          presentationRevision &+= 1
        })
    case let .empty(text):
      VStack(spacing: 6) {
        AIMIcon(name: .search).aimText(.section).foregroundStyle(.secondary)
        Text(text).aimText(.body)
      }
      .frame(maxWidth: .infinity, minHeight: 120)
      .padding(.horizontal, 12)
    case .bottomSpace:
      Color.clear.frame(height: 8)
    case .loadMore:
      HStack(spacing: 6) {
        if model.isChatPageLoading { ProgressView().controlSize(.mini) }
        AIMButton(title: model.isChatPageLoading ? "Loading messages" : "Load more messages",
          disabled: model.isChatPageLoading) { Task { await model.loadMoreChatMessages() } }
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
    var parts: [String] = []
    if let directory = thread.workingDirectory {
      let project = URL(fileURLWithPath: directory).lastPathComponent
      if !project.isEmpty { parts.append(project) }
    }
    parts.append(thread.updatedAt.formatted(date: .abbreviated, time: .shortened))
    if thread.archived { parts.append("Archived") }
    return parts.joined(separator: "  ·  ")
  }

  @MainActor
  private func updatePresentations() async {
    guard let detail = model.selectedChat else {
      presentations = [:]
      return
    }
    do {
      let rendered = try await ChatMessagePresenter.render(messages: detail.messages.filter { presentations[$0.id] == nil })
      guard !Task.isCancelled,
        model.selectedChatID == detail.thread.id,
        model.selectedChat?.thread.fileByteCount == detail.thread.fileByteCount
      else { return }
      let ids = Set(detail.messages.map(\.id))
      presentations = presentations.filter { ids.contains($0.key) }
      presentations.merge(rendered) { _, new in new }
      presentationRevision &+= 1
    } catch is CancellationError {
      return
    } catch {
      presentations = [:]
    }
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

private enum ChatDetailListItem: Identifiable, Equatable {
  case message(ChatMessage, separated: Bool)
  case empty(String)
  case bottomSpace
  case loadMore

  var id: String {
    switch self {
    case let .message(message, _): "message:\(message.id)"
    case let .empty(text): "empty:\(text)"
    case .bottomSpace: "bottom-space"
    case .loadMore: "load-more"
    }
  }
}

private struct ChatMessageSearchKey: Hashable {
  let threadID: String?
  let query: String
  let filterMask: Int
  let fileByteCount: Int64
}

private struct ChatPresentationKey: Hashable {
  let threadID: String?
  let fileByteCount: Int64
  let messageIDs: [String]
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
      copied = true
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(1.2))
        copied = false
      }
    } label: {
      Label(copied ? "Copied" : "Copy shown",
        systemImage: copied ? AIMIcon.Name.check.symbol : AIMIcon.Name.copy.symbol)
    }
    // The shared 28 pt push button: even side padding and a 6 pt icon-to-label gap.
    .buttonStyle(AIMPushButtonStyle())
    .disabled(messages.isEmpty)
    .help("Copy the messages currently shown")
    .accessibilityLabel(copied ? "Copied" : "Copy shown messages")
  }
}

private struct ChatMessageRow: View {
  let message: ChatMessage
  let presentation: ChatMessagePresentation?
  let fallbackText: AttributedString
  let separated: Bool
  /// A very long message shows a collapsed preview with Show more; the copy button always copies
  /// the full original text.
  let expanded: Bool
  let toggleExpanded: () -> Void
  @State private var hovered = false

  static let collapsedHeight: CGFloat = 260

  private var isLong: Bool {
    message.text.utf8.count > 1_800 || message.text.utf8.reduce(0) { $1 == 10 ? $0 + 1 : $0 } > 16
  }

  var body: some View {
    VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 5) {
      HStack(spacing: 5) {
        Text(message.role.displayName)
        if let timestamp = message.timestamp {
          Text("·")
          Text(timestamp, style: .time).monospacedDigit()
        }
        ChatCopyButton(text: message.text, label: "Copy message", emphasized: hovered)
      }
      .aimText(.secondary)

      VStack(alignment: .leading, spacing: AIMTheme.rowSpacing) {
        if isLong && !expanded {
          ChatMessageBlocks(presentation: presentation, fallbackText: fallbackText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(height: Self.collapsedHeight, alignment: .top)
            .clipped()
            // The preview fades out instead of cutting a line in half.
            .mask(alignment: .top) {
              VStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                  .frame(height: 40)
              }
            }
        } else {
          ChatMessageBlocks(presentation: presentation, fallbackText: fallbackText)
        }
        if isLong {
          Button(action: toggleExpanded) {
            Text(expanded ? "Show less" : "Show more")
              .aimFont(.body).foregroundStyle(AIMTheme.linkColor)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel(expanded ? "Show less of this message" : "Show the whole message")
        }
      }
      .padding(.horizontal, AIMTheme.sectionSpacing)
      .padding(.vertical, AIMTheme.rowSpacing + 2)
      .frame(maxWidth: message.role == .user ? 460 : 620, alignment: .leading)
      .background(messageSurface)
      .clipShape(RoundedRectangle(cornerRadius: AIMTheme.radius))
    }
    .frame(maxWidth: 620, alignment: message.role == .user ? .trailing : .leading)
    // The right side gives the scroll bar gutter back, so a bubble ends on the card's 16 pt inset.
    .padding(.leading, AIMTheme.sectionSpacing)
    .padding(.trailing, AIMTheme.sectionSpacing - AIMScroller.gutter)
    .padding(.top, separated ? 10 : 4)
    .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    .onHover { hovered = $0 }
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

private struct ChatMessageBlocks: View {
  let presentation: ChatMessagePresentation?
  let fallbackText: AttributedString

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let presentation {
        ForEach(presentation.blocks) { block in
          ChatPresentationBlockView(block: block)
        }
        if presentation.sourceWasTruncated {
          Text("This long message is shortened in the reader.")
            .aimText(.secondary, tint: AIMTheme.amber)
        }
      } else {
        Text(fallbackText)
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

  @ViewBuilder var body: some View {
    switch block {
    case let .paragraph(_, text):
      readable(text)
    case let .heading(_, level, text):
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
    case let .code(_, language, preview, expanded, sourceWasTruncated):
      ChatCodeBlock(
        language: language, preview: preview, expandedText: expanded,
        sourceWasTruncated: sourceWasTruncated)
    case .divider:
      AIMHairline().padding(.vertical, 2)
    }
  }

  private func readable(_ text: AttributedString) -> some View {
    Text(text)
      .aimText(.body)
      .lineSpacing(4)
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct ChatCodeBlock: View {
  let language: String?
  let preview: String
  let expandedText: String?
  let sourceWasTruncated: Bool
  @State private var expanded = false

  private var visibleText: String { expanded ? (expandedText ?? preview) : preview }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: AIMTheme.rowSpacing) {
        Text(language?.uppercased() ?? "CODE")
          .aimText(.secondary, monospaced: true)
        Spacer()
        ChatCopyButton(text: expandedText ?? preview, label: "Copy code", emphasized: true)
      }
      .padding(.horizontal, 10)
      .frame(height: 30)
      .background(AIMTheme.chatOtherSurface)

      Text(visibleText)
        .aimText(.secondary, monospaced: true, tint: .primary)
        .lineSpacing(3)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)

      if expandedText != nil {
        Button(expanded ? "Show less" : "Show more") { expanded.toggle() }
          .buttonStyle(.borderless)
          .padding(.horizontal, 10)
          .padding(.bottom, 9)
      } else if sourceWasTruncated {
        Text("Code shortened")
          .aimText(.secondary, tint: AIMTheme.amber)
          .padding(.horizontal, 10)
          .padding(.bottom, 9)
      }
    }
    .background(AIMTheme.chatCodeSurface)
    .clipShape(RoundedRectangle(cornerRadius: AIMTheme.radius))
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
      copied = true
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(1.2))
        copied = false
      }
    } label: {
      AIMIcon(name: copied ? .check : .copy)
        .aimFont(.secondary)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .foregroundStyle(copied ? AIMTheme.green : Color.secondary)
    .opacity(emphasized || copied ? 1 : 0.48)
    .help(copied ? "Copied" : label)
    .accessibilityLabel(copied ? "Copied" : label)
  }

}
