import AIManagerCore
import AppKit
import SwiftUI

/// One row of the message list. Equality compares a content token, never the full text, so a diff
/// of a long conversation stays cheap while a changed message (a new presentation, a changed
/// separator) still reloads and measures its row again.
struct ChatRowItem: Identifiable, Equatable {
  enum Kind {
    case message(ChatMessage, presentation: ChatMessagePresentation?, expanded: Set<Int>, separated: Bool)
    case empty(String)
    case loadMore(loading: Bool)
    case bottomSpace
  }

  let id: String
  let kind: Kind
  /// A row added after the first page fades in once.
  var fadesIn = false
  let token: Int

  init(id: String, kind: Kind, fadesIn: Bool = false) {
    self.id = id
    self.kind = kind
    self.fadesIn = fadesIn
    var hasher = Hasher()
    switch kind {
    case let .message(message, presentation, expanded, separated):
      hasher.combine(message.text.utf8.count)
      hasher.combine(expanded.sorted())
      hasher.combine(message.role)
      hasher.combine(separated)
      hasher.combine(presentation?.blocks.count ?? -1)
      hasher.combine(presentation?.sourceWasTruncated ?? false)
    case let .empty(text): hasher.combine(text)
    case let .loadMore(loading): hasher.combine(loading)
    case .bottomSpace: hasher.combine(0)
    }
    token = hasher.finalize()
  }

  static func == (left: ChatRowItem, right: ChatRowItem) -> Bool {
    left.id == right.id && left.token == right.token
  }

  var message: ChatMessage? {
    if case let .message(message, _, _, _) = kind { return message }
    return nil
  }

  /// A quick height guess for a row that is not measured yet: one line per wrapped text line.
  func estimatedHeight(width: CGFloat) -> CGFloat {
    switch kind {
    case .message:
      guard let text = message?.text else { return 72 }
      let perLine = max(24, Int((width - 72) / 7.6))
      var lines = 0
      for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        lines += max(1, (line.utf8.count + perLine - 1) / perLine)
      }
      return CGFloat(min(lines, 4_000)) * 20 + 72
    case .empty: return 120
    case .loadMore: return 32
    case .bottomSpace: return 8
    }
  }
}

/// A virtual list of hosted message rows. Every row is as tall as its content needs at the
/// current width: heights are measured at the real width, measured again when a row's content or the
/// width changes (for rows on screen at once and for all the others in short time slices), and
/// the reader's place holds still while rows above it settle.
struct ChatMessageList: NSViewRepresentable {
  let items: [ChatRowItem]
  /// Where to scroll once, when the row with this message exists; nil starts at the top.
  let restore: ChatScrollAnchor?
  let onReachEnd: () -> Void
  let onAnchor: (ChatScrollAnchor) -> Void
  let rowContent: (ChatRowItem) -> AnyView
  @Environment(\.aimCopyPath) private var copyPath

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> AIMOwnedScrollView {
    let scrollView = AIMOwnedScrollView(frame: .zero)
    let tableView = AIMVirtualTableView(frame: .zero)
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("content"))
    column.resizingMask = .autoresizingMask
    tableView.addTableColumn(column)
    tableView.headerView = nil
    tableView.backgroundColor = .clear
    tableView.style = .plain
    tableView.selectionHighlightStyle = .none
    tableView.intercellSpacing = .zero
    tableView.usesAutomaticRowHeights = false
    tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    tableView.focusRingType = AIMFocus.ringType
    tableView.delegate = context.coordinator
    tableView.dataSource = context.coordinator
    scrollView.documentView = tableView
    scrollView.contentView.postsBoundsChangedNotifications = true
    let coordinator = context.coordinator
    coordinator.tableView = tableView
    coordinator.scrollObserver = NotificationCenter.default.addObserver(
      forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
    ) { [weak coordinator] _ in MainActor.assumeIsolated { coordinator?.scrolled() } }
    scrollView.onWidthChange = { [weak coordinator] width in coordinator?.widthChanged(width) }
    scrollView.onReachEnd = onReachEnd
    apply(to: coordinator)
    tableView.reloadData()
    return scrollView
  }

  func updateNSView(_ scrollView: AIMOwnedScrollView, context: Context) {
    scrollView.onReachEnd = onReachEnd
    apply(to: context.coordinator)
    context.coordinator.widthChanged(scrollView.contentSize.width)
  }

  static func dismantleNSView(_ scrollView: AIMOwnedScrollView, coordinator: Coordinator) {
    if let observer = coordinator.scrollObserver { NotificationCenter.default.removeObserver(observer) }
    coordinator.stop()
  }

  private func apply(to coordinator: Coordinator) {
    coordinator.update(items: items, restore: restore, onAnchor: onAnchor, rowContent: rowContent, copyPath: copyPath)
  }

  @MainActor
  final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    weak var tableView: NSTableView?
    var scrollObserver: NSObjectProtocol?
    private var items: [ChatRowItem] = []
    private var rowContent: ((ChatRowItem) -> AnyView)?
    private var copyPath: @MainActor (String) -> Bool = { _ in false }
    private var onAnchor: ((ChatScrollAnchor) -> Void)?
    private var width: CGFloat = 0
    private var pendingRestore: ChatScrollAnchor?
    private var restored = false
    private var pinnedToBottom = false
    private var pinning = false
    private var viewportHeight: CGFloat = 0
    private var anchorTask: Task<Void, Never>?
    private var sliceScheduled = false
    private var stopped = false
    private let measurer = NSHostingController(rootView: AnyView(EmptyView()))

    private struct Measured {
      var token: Int
      var width: Int
      var height: CGFloat
      var exact: Bool
    }
    private var heights: [String: Measured] = [:]

    func stop() {
      stopped = true
      anchorTask?.cancel()
    }

    /// The column follows the scroll view's width. Rows measured at another width keep their old
    /// height as an estimate, are measured again for the rows on screen at once, and the others follow in slices.
    func widthChanged(_ next: CGFloat) {
      guard let tableView, next > 0, abs(next - width) > 0.5 else { return }
      width = next
      tableView.tableColumns.first?.width = next
      for (id, value) in heights { heights[id] = Measured(token: value.token, width: value.width, height: value.height, exact: false) }
      guard !items.isEmpty else { return }
      settle(all: true)
      restoreIfPossible()
    }

    func update(
      items nextItems: [ChatRowItem], restore: ChatScrollAnchor?, onAnchor: @escaping (ChatScrollAnchor) -> Void,
      rowContent: @escaping (ChatRowItem) -> AnyView, copyPath: @escaping @MainActor (String) -> Bool
    ) {
      self.rowContent = rowContent
      self.copyPath = copyPath
      self.onAnchor = onAnchor
      if !restored, pendingRestore == nil { pendingRestore = restore }
      let oldItems = items
      items = nextItems
      guard let tableView else { return }
      if oldItems.map(\.id) == nextItems.map(\.id) {
        let changed = IndexSet(nextItems.indices.filter { oldItems[$0] != nextItems[$0] })
        guard !changed.isEmpty else { return }
        tableView.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0))
        settle(rows: changed)
      } else {
        tableView.reloadData()
        settle(all: true)
      }
      restoreIfPossible()
    }

    // MARK: Heights

    private func currentHeight(of item: ChatRowItem) -> CGFloat {
      // A row whose content changed keeps its last height until it is measured again.
      if let measured = heights[item.id] { return measured.height }
      return item.estimatedHeight(width: width)
    }

    private func isExact(_ item: ChatRowItem) -> Bool {
      guard let measured = heights[item.id] else { return false }
      return measured.token == item.token && measured.exact && measured.width == Int(width.rounded())
    }

    /// Auto layout would measure a hosted SwiftUI text at its single-line ideal width, so the
    /// height comes from a hosting controller asked for the real column width.
    private func measure(_ item: ChatRowItem) -> CGFloat {
      guard let rowContent, width > 0 else { return item.estimatedHeight(width: width) }
      measurer.rootView = AnyView(
        rowContent(item).environment(\.aimCopyPath, copyPath).environment(\.uiLintSuppressed, true)
          .foregroundStyle(.primary).id(item.id))
      let size = measurer.sizeThatFits(in: CGSize(width: max(width, 1), height: .greatestFiniteMagnitude))
      let height = max(1, ceil(size.height))
      heights[item.id] = Measured(token: item.token, width: Int(width.rounded()), height: height, exact: true)
      return height
    }

    /// Measures the rows on screen (and a screen above and below) at once and applies them;
    /// `all` also queues every other row.
    private func settle(rows only: IndexSet? = nil, all: Bool = false) {
      guard let tableView, width > 0 else { return }
      var targets = IndexSet()
      if let only {
        targets = only
      } else if let range = nearbyRange(tableView) {
        targets = IndexSet(integersIn: range)
      }
      var changed = IndexSet()
      for row in targets where items.indices.contains(row) {
        let item = items[row]
        if isExact(item) { continue }
        let before = tableView.rect(ofRow: row).height
        let height = measure(item)
        if abs(before - height) > 0.5 { changed.insert(row) }
      }
      apply(heightChangesIn: changed)
      if all || only != nil { scheduleSlice() }
    }

    private func nearbyRange(_ tableView: NSTableView) -> Range<Int>? {
      guard let scroll = tableView.enclosingScrollView, !items.isEmpty else { return nil }
      let clip = scroll.contentView.bounds
      let area = clip.insetBy(dx: 0, dy: -clip.height)
      let visible = tableView.rows(in: area)
      if visible.location == NSNotFound || visible.length == 0 { return 0..<min(items.count, 12) }
      return visible.location..<min(items.count, visible.location + visible.length + 1)
    }

    /// Tells the table the new heights without animation and keeps the reader's place: the row at
    /// the top of the view stays at the same offset while rows above it change.
    private func apply(heightChangesIn rows: IndexSet) {
      guard let tableView, !rows.isEmpty, let scroll = tableView.enclosingScrollView else { return }
      let clip = scroll.contentView
      let anchorRow = tableView.row(at: NSPoint(x: 1, y: clip.bounds.minY + 1))
      let offset = anchorRow >= 0 ? clip.bounds.minY - tableView.rect(ofRow: anchorRow).minY : 0
      let keepBottom = pinnedToBottom
      if keepBottom { pinning = true }
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0
        context.allowsImplicitAnimation = false
        tableView.noteHeightOfRows(withIndexesChanged: rows)
      }
      if keepBottom {
        pinning = false
        pinnedToBottom = true
        pinBottom()
        return
      }
      if anchorRow >= 0, anchorRow < items.count, pendingRestore == nil || restored {
        let y = tableView.rect(ofRow: anchorRow).minY + offset
        if abs(y - clip.bounds.minY) > 0.5 {
          clip.scroll(to: NSPoint(x: 0, y: max(0, y)))
          scroll.reflectScrolledClipView(clip)
        }
      }
    }

    /// Measures the rows that are still estimates, a few milliseconds at a time.
    private func scheduleSlice() {
      guard !sliceScheduled, !stopped else { return }
      sliceScheduled = true
      DispatchQueue.main.async { [weak self] in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.sliceScheduled = false
          self.runSlice()
        }
      }
    }

    private func runSlice() {
      guard !stopped, let tableView, width > 0 else { return }
      let start = CFAbsoluteTimeGetCurrent()
      var changed = IndexSet()
      var remaining = false
      // From the rows on screen outward: first below them, then above.
      let first = nearbyRange(tableView)?.lowerBound ?? 0
      for row in Array(first..<items.count) + Array(0..<first) {
        let item = items[row]
        if isExact(item) { continue }
        if CFAbsoluteTimeGetCurrent() - start > 0.008 { remaining = true; break }
        let before = tableView.rect(ofRow: row).height
        if abs(measure(item) - before) > 0.5 { changed.insert(row) }
      }
      apply(heightChangesIn: changed)
      if remaining { scheduleSlice() }
    }

    // MARK: Place

    /// Scrolls to the remembered message once its row exists.
    private func restoreIfPossible() {
      guard !restored, let target = pendingRestore, let tableView, width > 0,
        let row = items.firstIndex(where: { $0.message?.id == target.messageID }),
        let scroll = tableView.enclosingScrollView
      else { return }
      // Rows from the place to the end are exact, so the end of the list is not underestimated.
      settle(rows: IndexSet(integersIn: row..<min(items.count, row + 30)))
      // The table frame can lag behind the rows at this moment, so the end comes from the last row.
      let travel = max(0, tableView.rect(ofRow: items.count - 1).maxY - scroll.contentView.bounds.height)
      let wanted = max(0, tableView.rect(ofRow: row).minY + target.offset)
      // The place is below the rows loaded so far: load the next page first, then try again.
      if wanted > travel, items.contains(where: { if case .loadMore = $0.kind { return true } else { return false } }) {
        (scroll as? AIMOwnedScrollView)?.onReachEnd?()
        return
      }
      restored = true
      pendingRestore = nil
      pinnedToBottom = row == items.lastIndex(where: { $0.message != nil })
        && !items.contains(where: { if case .loadMore = $0.kind { return true } else { return false } })
      if pinnedToBottom {
        pinBottom()
      } else {
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(wanted, travel)))
        scroll.reflectScrolledClipView(scroll.contentView)
      }
      settle(all: true)
    }

    private func pinBottom() {
      guard !pinning, let tableView, !items.isEmpty, let scroll = tableView.enclosingScrollView else { return }
      pinning = true
      defer { pinning = false }
      let clip = scroll.contentView
      viewportHeight = clip.bounds.height
      let travel = max(0, tableView.rect(ofRow: items.count - 1).maxY - clip.bounds.height)
      clip.scroll(to: NSPoint(x: 0, y: travel))
      scroll.reflectScrolledClipView(clip)
    }

    func scrolled() {
      guard !pinning, let tableView, let clip = tableView.enclosingScrollView?.contentView else { return }
      if pinnedToBottom, abs(viewportHeight - clip.bounds.height) > 0.5 {
        pinBottom()
      } else if !items.isEmpty {
        let travel = max(0, tableView.rect(ofRow: items.count - 1).maxY - clip.bounds.height)
        pinnedToBottom = travel > 0 && abs(clip.bounds.minY - travel) <= 1
          && !items.contains(where: { if case .loadMore = $0.kind { return true } else { return false } })
      }
      viewportHeight = clip.bounds.height
      // Rows about to show are exact before they draw, even when the reader outruns the slices.
      settle()
      guard restored || pendingRestore == nil, let onAnchor else { return }
      anchorTask?.cancel()
      anchorTask = Task { @MainActor [weak self] in
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled, let self, let tableView = self.tableView,
          let clip = tableView.enclosingScrollView?.contentView else { return }
        if !self.items.contains(where: { if case .loadMore = $0.kind { return true } else { return false } }),
          let last = self.items.lastIndex(where: { $0.message != nil }),
          abs(clip.bounds.maxY - tableView.rect(ofRow: self.items.count - 1).maxY) <= 1,
          let message = self.items[last].message {
          onAnchor(ChatScrollAnchor(messageID: message.id, offset: clip.bounds.minY - tableView.rect(ofRow: last).minY))
          return
        }
        let row = tableView.row(at: NSPoint(x: 1, y: clip.bounds.minY + 1))
        guard row >= 0, row < self.items.count else { return }
        var index = row
        // A load-more or spacer row has no message; the anchor is the nearest message below.
        while index < self.items.count {
          if let message = self.items[index].message {
            onAnchor(ChatScrollAnchor(
              messageID: message.id, offset: clip.bounds.minY - tableView.rect(ofRow: index).minY))
            return
          }
          index += 1
        }
      }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
      guard items.indices.contains(row) else { return 24 }
      return currentHeight(of: items[row])
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
      guard items.indices.contains(row), let rowContent else { return nil }
      let identifier = NSUserInterfaceItemIdentifier("ChatRowCell")
      let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? ChatRowCell
        ?? ChatRowCell(identifier: identifier)
      // The id gives a recycled cell fresh view state for its new item.
      cell.host.rootView = AnyView(
        rowContent(items[row]).environment(\.aimCopyPath, copyPath).foregroundStyle(.primary).id(items[row].id))
      return cell
    }
  }
}

final class ChatRowCell: NSTableCellView {
  let host = NSHostingView(rootView: AnyView(EmptyView()))

  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier
    focusRingType = .none
    host.translatesAutoresizingMaskIntoConstraints = false
    host.focusRingType = .none
    addSubview(host)
    NSLayoutConstraint.activate([
      host.leadingAnchor.constraint(equalTo: leadingAnchor),
      host.trailingAnchor.constraint(equalTo: trailingAnchor),
      host.topAnchor.constraint(equalTo: topAnchor),
      host.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  @available(*, unavailable) required init?(coder: NSCoder) { nil }
}
