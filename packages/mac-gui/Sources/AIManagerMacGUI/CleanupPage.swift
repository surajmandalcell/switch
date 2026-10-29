import AIManagerCore
import AppKit
import SwiftUI

enum CleanupCheckState { case off, mixed, on }

/// A checkbox with a third "some" state, drawn like the shared checkbox.
struct CleanupCheck: View {
  let state: CleanupCheckState
  let label: String
  var disabled = false
  let action: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let box = RoundedRectangle(cornerRadius: 4, style: .continuous)
    Button(action: action) {
      ZStack {
        box.fill(state == .off ? AIMTheme.controlFill : AIMTheme.checkedControlFill)
        Color.clear.aimBorder(state == .off ? AIMTheme.controlBorder : Color.clear, in: box)
        if state != .off {
          Image(systemName: state == .on ? "checkmark" : "minus").aimFont(.caption).fontWeight(.bold)
            .foregroundStyle(Color.white)
        }
      }
      .frame(width: 16, height: 16)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .opacity(disabled ? 0.45 : 1)
    .disabled(disabled)
    .animation(reduceMotion ? nil : AIMMotion.fade(AIMMotion.state), value: state)
    .accessibilityLabel(label)
    .accessibilityValue(state == .on ? "Checked" : (state == .mixed ? "Some checked" : "Unchecked"))
    .accessibilityAddTraits(.isToggle)
  }
}

/// How far a row's hover fill sits from the card's edges and the hairline under the title: the same on every side.
private let cleanupHoverInset: CGFloat = 6

/// One row of the cleanup list: a hover fill, then the content on the card's inset.
struct CleanupRowBox<Content: View>: View {
  var indent: CGFloat = 0
  var minHeight: CGFloat = AIMTheme.rowHeight
  @ViewBuilder var content: Content
  @State private var hovering = false

  var body: some View {
    HStack(spacing: AIMTheme.rowSpacing) { content }
      .padding(.leading, AIMTheme.cardInset + indent)
      .padding(.trailing, AIMTheme.cardInset)
      .padding(.vertical, 4)
      .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
      .background {
        RoundedRectangle(cornerRadius: AIMTheme.tileRadius, style: .continuous)
          .fill(AIMTheme.rowHover).opacity(hovering ? 1 : 0)
          .padding(.horizontal, cleanupHoverInset).padding(.vertical, AIMTheme.highlightInset)
          .animation(AIMMotion.fade(AIMMotion.hover), value: hovering)
          .allowsHitTesting(false)
      }
      .contentShape(Rectangle())
      .onHover { hovering = $0 }
  }
}

/// A reviewed cleanup: exact items and bytes, waiting for one confirmation.
struct CleanupReview {
  struct Group: Identifiable { let id: String; let title: String; let count: Int; let bytes: Int64 }
  let plan: ConversationCleanupPlan?
  let groups: [Group]
  let samples: [CleanupUsageSample]
  let clearIndex: Bool
  var itemCount: Int { plan?.items.count ?? 0 }
  var bytes: Int64 { (plan?.bytes ?? 0) }
}

struct CleanupPage: View {
  @ObservedObject var model: AccountViewModel
  @ObservedObject var store: MaintenanceStore
  @AppStorage(MaintenancePlace.rangeKey) private var rangeRaw = CleanupDateRange.olderMonth.rawValue
  @AppStorage(MaintenancePlace.fromKey) private var fromTime = Date().addingTimeInterval(-30 * 86_400).timeIntervalSince1970
  @AppStorage(MaintenancePlace.throughKey) private var throughTime = Date().timeIntervalSince1970
  @AppStorage(MaintenancePlace.expandedKey) private var expandedRaw = ""
  @AppStorage("cleanupProjects") private var projectsData = Data()
  @AppStorage("cleanupTitle") private var titleQuery = ""
  @FocusState private var titleFocused: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var scan: CleanupScan?
  @State private var scannedSourceID: String?
  @State private var trash: [ConversationCleanupBatch] = []
  @State private var samples: [CleanupUsageSample] = []
  @State private var sizes = RebuildableCacheSizes(usageBytes: 0, conversationBytes: 0)
  @State private var selection: Set<String> = []
  @State private var selectionRevision = 0
  @State private var useSamples = false
  @State private var clearIndex = false
  @State private var anchor = Date()
  @State private var loading = false
  @State private var error: String?
  @State private var review: CleanupReview?
  @State private var showReviewItems = false
  @State private var confirming = false
  @State private var removingBatch: ConversationCleanupBatch?

  private var source: CleanupSource? { store.cleanupSource }
  private var busy: Bool { loading || model.isBusy }
  private var range: CleanupDateRange {
    get { CleanupDateRange(rawValue: rangeRaw) ?? .olderMonth }
    nonmutating set { rangeRaw = newValue.rawValue }
  }
  private var from: Date {
    get { Date(timeIntervalSince1970: fromTime) }
    nonmutating set { fromTime = newValue.timeIntervalSince1970 }
  }
  private var through: Date {
    get { Date(timeIntervalSince1970: throughTime) }
    nonmutating set { throughTime = newValue.timeIntervalSince1970 }
  }
  private var expanded: Set<String> {
    get { Set(expandedRaw.split(separator: "\n").map(String.init)) }
    nonmutating set { expandedRaw = newValue.sorted().joined(separator: "\n") }
  }

  // MARK: Derived data

  private func matches(_ date: Date) -> Bool { range.contains(date, now: anchor, from: from, through: through) }
  /// Old app versions and the like are not dated by use, so every range shows them.
  private func visible(_ category: CleanupCategory) -> [CleanupItem] {
    let items = category.ageBased ? category.selectable.filter { matches($0.updatedAt) } : category.selectable
    return ["conversations", "archived", "agents"].contains(category.id) ? items.filter(conversationFilter.matches) : items
  }
  private var projects: Set<String> {
    get { Set((try? JSONDecoder().decode([String].self, from: projectsData)) ?? []) }
    nonmutating set { projectsData = (try? JSONEncoder().encode(newValue.sorted())) ?? Data() }
  }
  private var conversationFilter: ConversationCleanupFilter {
    ConversationCleanupFilter(projects: projects, title: titleQuery)
  }
  private var conversations: [CleanupItem] {
    (scan?.categories ?? []).filter { ["conversations", "archived", "agents"].contains($0.id) }.flatMap(\.items)
  }
  private var matchingConversations: [CleanupItem] {
    conversations.filter { matches($0.updatedAt) && conversationFilter.matches($0) }
  }
  private var visibleSamples: [CleanupUsageSample] { samples.filter { matches($0.fetchedAt) } }
  private var shownCategories: [CleanupCategory] { (scan?.categories ?? []).filter { !visible($0).isEmpty } }
  /// A chat picked for removal drops its own pasted-images row, so one file is never handled twice.
  private var selectedItems: [CleanupItem] {
    let picked = (scan?.categories ?? []).flatMap { visible($0) }.filter { selection.contains($0.id) }
    let removed = Set(picked.filter { !$0.isRewrite }.map(\.path))
    return picked.filter { !$0.isRewrite || !removed.contains($0.path) }
  }
  private var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.bytes } }
  private var hasSelection: Bool { !selection.isEmpty || (useSamples && !visibleSamples.isEmpty) || clearIndex }

  var body: some View {
    VStack(spacing: AIMTheme.cardGap) {
      controls
      if source == nil && (!store.isLoaded || !model.hasLoaded) {
        AIMSection { AIMSectionLoadingRows() }
      } else if source == nil {
        AIMSection { Text("No supported tool was found on this Mac.").aimText(.secondary) }
      } else if scan == nil && error == nil {
        AIMSection("Files") { AIMSectionLoadingRows() }
      } else if scan == nil {
        EmptyView()
      } else {
        conversationCard
        // Expanded lists can contain native tables; flatten their SwiftUI headers separately.
        if expanded.isEmpty {
          categoriesCard.drawingGroup()
        } else {
          categoriesCard
        }
        if source?.tool == .codex, !samples.isEmpty || sizes.conversationBytes > 0 { cacheCard }
        selectionCard.drawingGroup()
        if let review { reviewCard(review) }
        if !trash.isEmpty { trashCard }
      }
      errorCard
    }
    .task(id: source?.id) {
      if scan == nil || scannedSourceID != source?.id { await reload() }
    }
    .onChange(of: rangeRaw) { _, _ in resetSelection() }
    .onChange(of: fromTime) { _, _ in resetSelection() }
    .onChange(of: throughTime) { _, _ in resetSelection() }
    .onChange(of: projectsData) { _, _ in resetSelection() }
    .onChange(of: titleQuery) { _, _ in resetSelection() }
    .onChange(of: clearIndex) { _, _ in review = nil }
    .alert("Move \(review?.itemCount.formatted() ?? "0") items to the trash?", isPresented: $confirming) {
      Button("Cancel", role: .cancel) {}
      Button("Move to trash") { Task { await apply() } }
    } message: {
      Text("\(MaintenanceStore.size(review?.bytes ?? 0)) (\((review?.bytes ?? 0).formatted()) bytes) move to Switch's recoverable trash. Restore brings them back. Nothing is deleted for good.")
    }
    .alert("Remove these items for good?", isPresented: Binding(
      get: { removingBatch != nil }, set: { if !$0 { removingBatch = nil } }), presenting: removingBatch) { batch in
      Button("Cancel", role: .cancel) { removingBatch = nil }
      Button("Remove for good", role: .destructive) { Task { await remove(batch) } }
    } message: { batch in
      Text("\(batch.items.count.formatted()) items (\(MaintenanceStore.size(batch.bytes))) leave the trash. This cannot be undone.")
    }
  }

  // MARK: Controls

  private var controls: some View {
    AIMSection {
      HStack(spacing: AIMTheme.sectionSpacing) {
        CleanupRangeSelect(selection: Binding(get: { range }, set: { range = $0 })).disabled(busy)
        if range == .before {
          AIMDateField(title: "Before", selection: Binding(get: { from }, set: { from = $0 }))
        } else if range == .custom {
          AIMDateField(title: "From", selection: Binding(get: { from }, set: { from = $0 }))
          AIMDateField(title: "Through", selection: Binding(get: { through }, set: { through = $0 }), after: from)
        }
        Spacer(minLength: 0)
        if loading { ProgressView().controlSize(.small) }
        AIMButton(title: "Reload", icon: .refresh, disabled: busy) { Task { await reload() } }
      }
    }
  }

  // MARK: Categories

  private var conversationCard: some View {
    let items = matchingConversations
    let choices = Set(conversations.map { $0.project ?? "" }).sorted()
    return AIMSection("Delete conversations by filter", accessory: {
      Text("\(items.count.formatted()) conversations · \(MaintenanceStore.size(items.reduce(0) { $0 + $1.bytes }))")
        .aimText(.secondary).monospacedDigit()
    }) {
      HStack(spacing: AIMTheme.rowSpacing) {
        Menu {
          Button("All projects") { projects = [] }
          ForEach(choices, id: \.self) { path in
            Button {
              var next = projects
              if !next.insert(path).inserted { next.remove(path) }
              projects = next
            } label: {
              Label(path.isEmpty ? "No project" : path, systemImage: projects.contains(path) ? "checkmark" : "folder")
            }
          }
        } label: { Text(projects.isEmpty ? "All projects" : "\(projects.count) projects") }
        .menuStyle(.borderlessButton).fixedSize()
        Text("Title").aimText(.secondary)
        TextField("Match title text", text: $titleQuery).textFieldStyle(.plain).focused($titleFocused)
          .aimFieldChrome(focused: titleFocused).accessibilityLabel("Conversation title contains")
          .frame(minWidth: 300)
      }
      Text("Use the app picker above and the date range to narrow this list. Active and protected conversations stay untouched.")
        .aimText(.secondary)
      if items.isEmpty {
        Text("No conversations match. Change the filters or choose another app.").aimText(.secondary)
      } else {
        AIMVirtualList(items: items, fixedRowHeight: 48) { item in
          AnyView(HStack {
            VStack(alignment: .leading, spacing: 2) {
              Text(item.title).aimText(.body).lineLimit(1)
                .help(item.title)
              Text(item.project ?? "No project").aimText(.secondary).lineLimit(1).truncationMode(.middle)
                .help(item.project ?? "No project")
            }
            Spacer()
            Text(item.updatedAt.formatted(date: .abbreviated, time: .shortened)).aimText(.secondary).monospacedDigit()
            sizeColumn(item.bytes)
          }.padding(.horizontal, 4))
        }
        .frame(height: min(CGFloat(items.count), 5) * 48)
      }
      HStack {
        Text("Conversation dates are the last file update.").aimText(.secondary)
        Spacer()
        AIMButton(title: "Review \(items.count.formatted()) conversations", disabled: busy || items.isEmpty) {
          selection = Set(items.map(\.id))
          selectionRevision &+= 1
          useSamples = false
          clearIndex = false
          Task { await makeReview() }
        }
      }
    }
    .disabled(busy)
  }

  private var categoriesCard: some View {
    let categories = shownCategories
    // A pasted-images row shrinks a chat that its Conversations row already counts, so the totals skip it.
    let items = categories.filter { $0.id != "images" }.flatMap { visible($0) }
    let total = scan?.totalBytes ?? 0
    // The last row's text sits 9.5 pt above its bottom edge; 4.5 more makes the card's 14 pt end.
    return AIMCard(title: "Files you can clear", divider: true, bottomInset: 4.5, accessory: {
      Text("\(items.count.formatted()) items · \(MaintenanceStore.size(items.reduce(0) { $0 + $1.bytes })) of \(MaintenanceStore.size(total))")
        .aimText(.secondary).monospacedDigit().aimRolling(items.count)
    }) {
      if categories.isEmpty {
        HStack {
          Text(range.nothingText(tool: source?.title ?? "This tool", total: total)).aimText(.secondary)
          Spacer()
          if range != .all { AIMButton(title: "Show all time") { range = .all } }
        }
        .padding(.horizontal, AIMTheme.cardInset).padding(.vertical, AIMTheme.contentInset)
      } else {
        VStack(spacing: 0) {
          ForEach(Array(categories.enumerated()), id: \.element.id) { index, category in
            if index > 0 { AIMRowSeparator() }
            categoryBlock(category)
          }
        }
        // The first row's fill sits as far below the hairline as it does from the card's sides.
        .padding(.top, cleanupHoverInset - AIMTheme.highlightInset)
      }
    }
    .disabled(busy)
  }

  private func categoryBlock(_ category: CleanupCategory) -> some View {
    let items = visible(category)
    let open = expanded.contains(category.id)
    return VStack(spacing: 0) {
      CleanupRowBox(minHeight: 52) {
        disclosure(open: open) { toggleExpanded(category.id) }
        CleanupCheck(state: state(of: items), label: category.title) { toggle(items) }
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(category.title).aimText(.body).lineLimit(1)
              .help(category.title)
            if category.risk == .caution { Badge(text: "Check first", tint: AIMTheme.amber) }
          }
          Text(category.detail).aimText(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            .help(category.detail)
        }
        Spacer(minLength: AIMTheme.rowSpacing)
        countColumn(items.count)
        sizeColumn(items.reduce(0) { $0 + $1.bytes })
      }
      .drawingGroup()
      .onTapGesture { toggleExpanded(category.id) }
      if open {
        if category.byProject {
          projectRows(category, items)
        } else {
          itemRows(items, indent: 28, key: category.id)
        }
      }
    }
  }

  private func projectRows(_ category: CleanupCategory, _ items: [CleanupItem]) -> some View {
    let groups = Dictionary(grouping: items, by: { $0.project ?? "" })
      .map { (path: $0.key, items: $0.value) }
      .sorted { ($0.items.map(\.updatedAt).max() ?? .distantPast) > ($1.items.map(\.updatedAt).max() ?? .distantPast) }
    return VStack(spacing: 0) {
      ForEach(groups, id: \.path) { group in
        let id = "\(category.id)/\(group.path)"
        let open = expanded.contains(id)
        CleanupRowBox(indent: 28) {
          disclosure(open: open) { toggleExpanded(id) }
          CleanupCheck(state: state(of: group.items), label: projectName(group.path)) { toggle(group.items) }
          Text(projectName(group.path)).aimText(.body).lineLimit(1).truncationMode(.middle)
            .help(group.path.isEmpty ? "No project folder" : "\(projectName(group.path))\n\(group.path)")
          if !group.path.isEmpty {
            Text((group.path as NSString).abbreviatingWithTildeInPath).aimText(.secondary, monospaced: true)
              .lineLimit(1).truncationMode(.head)
              .help((group.path as NSString).abbreviatingWithTildeInPath)
          }
          Spacer(minLength: AIMTheme.rowSpacing)
          countColumn(group.items.count)
          sizeColumn(group.items.reduce(0) { $0 + $1.bytes })
        }
        .onTapGesture { toggleExpanded(id) }
        if open { itemRows(group.items, indent: 56, key: id) }
      }
    }
    .transition(.opacity)
  }

  @ViewBuilder private func itemRows(_ items: [CleanupItem], indent: CGFloat, key: String) -> some View {
    if items.count <= 12 {
      VStack(spacing: 0) { ForEach(items) { itemRow($0, indent: indent) } }.transition(.opacity)
    } else {
      AIMVirtualList(items: items, fixedRowHeight: AIMTheme.rowHeight, contentRevision: selectionRevision) { item in
        AnyView(itemRow(item, indent: indent))
      }
      .frame(height: min(CGFloat(items.count), 8) * AIMTheme.rowHeight)
      .transition(.opacity)
    }
  }

  private func itemRow(_ item: CleanupItem, indent: CGFloat) -> some View {
    CleanupRowBox(indent: indent) {
      CleanupCheck(state: selection.contains(item.id) ? .on : .off, label: item.title) { toggle([item]) }
      Text(item.title).aimText(.body).lineLimit(1).truncationMode(.middle).help("\(item.title)\n\(item.path)")
      Spacer(minLength: AIMTheme.rowSpacing)
      Text(item.updatedAt.formatted(date: .abbreviated, time: .omitted)).aimText(.secondary).monospacedDigit()
        .frame(width: Self.countWidth, alignment: .trailing)
        .help(item.updatedAt.formatted(date: .abbreviated, time: .omitted))
      sizeColumn(item.bytes)
    }
  }

  private func disclosure(open: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      AIMIcon(name: .chevron).aimFont(.secondary).foregroundStyle(.secondary)
        .rotationEffect(.degrees(open ? 90 : 0))
        .animation(reduceMotion ? nil : AIMMotion.fade(AIMMotion.slide), value: open)
        .frame(width: 12, height: 16)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(open ? "Collapse" : "Expand")
  }

  private static let countWidth: CGFloat = 96
  private static let sizeWidth: CGFloat = 80

  private func countColumn(_ count: Int) -> some View {
    Text("\(count.formatted()) \(count == 1 ? "item" : "items")").aimText(.secondary).monospacedDigit().frame(width: Self.countWidth, alignment: .trailing)
      .help("\(count.formatted()) \(count == 1 ? "item" : "items")")
  }
  private func sizeColumn(_ bytes: Int64) -> some View {
    Text(MaintenanceStore.size(bytes)).aimText(.body).monospacedDigit().lineLimit(1)
      .frame(width: Self.sizeWidth, alignment: .trailing)
      .help(MaintenanceStore.size(bytes))
  }
  private func projectName(_ path: String) -> String {
    path.isEmpty ? "No project" : URL(fileURLWithPath: path).lastPathComponent
  }

  // MARK: Switch cache (Codex)

  private var cacheCard: some View {
    AIMSection("Switch's own cache", accessory: {
      Text(MaintenanceStore.size(sizes.usageBytes + sizes.conversationBytes)).aimText(.secondary).monospacedDigit()
    }) {
      Toggle("Usage readings · \(visibleSamples.count.formatted()) in this range", isOn: Binding(
        get: { useSamples && !visibleSamples.isEmpty }, set: { useSamples = $0; review = nil }))
        .toggleStyle(AIMCheckboxToggleStyle()).disabled(visibleSamples.isEmpty)
      Toggle("Conversation index · \(MaintenanceStore.size(sizes.conversationBytes))", isOn: $clearIndex)
        .toggleStyle(AIMCheckboxToggleStyle()).disabled(range != .all || sizes.conversationBytes == 0)
        .help("Choose All time to clear the search index. It rebuilds when Chat History opens.")
      Text("These caches rebuild when needed. Daily activity totals stay saved.").aimText(.secondary)
    }
    .disabled(busy)
  }

  // MARK: Selection and review

  private var selectionCard: some View {
    AIMSection {
      if let untouched = scan?.untouchedText {
        HStack(spacing: 6) {
          AIMIcon(name: .info)
          Text(untouched)
        }
        .aimText(.secondary)
      }
      HStack {
        Text(hasSelection ? "\(selectedItems.count.formatted()) items selected" : "Nothing selected").aimText(.body)
        Text(MaintenanceStore.size(selectedBytes)).aimText(.secondary).monospacedDigit().aimRolling(selectedBytes)
        Spacer()
        AIMButton(title: "Review", tone: .primary, disabled: busy || !hasSelection) { Task { await makeReview() } }
      }
    }
  }

  private func reviewCard(_ review: CleanupReview) -> some View {
    AIMSection("Review before cleanup") {
      ForEach(review.groups) { group in
        HStack {
          Text(group.title).aimText(.body)
          Spacer()
          countColumn(group.count)
          sizeColumn(group.bytes)
        }
      }
      if !review.samples.isEmpty {
        HStack {
          Text("Usage readings").aimText(.body)
          Spacer()
          countColumn(review.samples.count)
          sizeColumn(review.samples.reduce(0) { $0 + $1.bytes })
        }
      }
      if review.clearIndex {
        HStack {
          Text("Conversation index").aimText(.body)
          Spacer()
          sizeColumn(sizes.conversationBytes)
        }
      }
      HStack {
        Text("Total").aimText(.body).fontWeight(.semibold)
        Spacer()
        countColumn(review.itemCount)
        Text(MaintenanceStore.size(review.bytes)).aimText(.body).fontWeight(.semibold).monospacedDigit()
          .frame(width: Self.sizeWidth, alignment: .trailing)
          .help(MaintenanceStore.size(review.bytes))
      }
      if let plan = review.plan {
        Button { withAnimation(AIMMotion.move(reduceMotion: reduceMotion)) { showReviewItems.toggle() } } label: {
          HStack(spacing: 6) {
            AIMIcon(name: .chevron).aimFont(.secondary).rotationEffect(.degrees(showReviewItems ? 90 : 0))
            Text(showReviewItems ? "Hide the exact items" : "Show the exact \(plan.items.count.formatted()) items")
          }
          .aimText(.body).foregroundStyle(AIMTheme.linkColor)
        }
        .buttonStyle(.plain)
        if showReviewItems {
          AIMVirtualList(items: plan.items, fixedRowHeight: 30) { item in
            AnyView(HStack {
              AIMCopyablePath(path: item.path).help(item.title)
              Spacer()
              Text(MaintenanceStore.size(item.bytes)).aimText(.secondary).monospacedDigit()
            }.padding(.horizontal, 4))
          }
          .frame(height: min(CGFloat(plan.items.count), 8) * 30)
          .transition(.opacity)
        }
      }
      Text(reviewNote(review)).aimText(.secondary)
      HStack {
        AIMButton(title: "Cancel") { self.review = nil }
        Spacer()
        AIMButton(title: "Move to trash", icon: .trash, tone: .primary, disabled: busy) { confirming = true }
      }
    }
    .transition(.opacity)
  }

  private func reviewNote(_ review: CleanupReview) -> String {
    var note = "Items move to Switch's recoverable trash inside the tool folder. Moving does not free disk space until you remove them for good."
    if review.groups.contains(where: { $0.id == "images" }) {
      note += " A chat that loses its pasted images keeps a copy without them; the original waits in the trash."
    }
    if source?.tool != .codex, review.groups.contains(where: { ["conversations", "archived"].contains($0.id) }) {
      note += " Usage totals for \(source?.title ?? "this tool") are read from its saved chats, so removed chats lower them."
    }
    return note
  }

  private var trashCard: some View {
    AIMSection("Recoverable trash", accessory: {
      Text("\(trash.count.formatted()) \(trash.count == 1 ? "batch" : "batches")").aimText(.secondary)
    }) {
      ForEach(trash) { batch in
        HStack(spacing: AIMTheme.sectionSpacing) {
          VStack(alignment: .leading, spacing: 2) {
            Text("\(batch.items.count.formatted()) items · \(MaintenanceStore.size(batch.bytes))").aimText(.body)
            Text(batch.createdAt.formatted(date: .abbreviated, time: .shortened)).aimText(.secondary).monospacedDigit()
          }
          Spacer()
          AIMButton(title: "Restore", disabled: busy) { Task { await restore(batch) } }
          AIMButton(title: "Remove for good", disabled: busy) { removingBatch = batch }
        }
      }
    }
    .transition(.opacity)
  }

  @ViewBuilder private var errorCard: some View {
    if let error {
      AIMSection { Notice(text: error, tone: AIMTheme.amber) }
        .transition(.opacity)
    }
  }

  // MARK: Selection helpers

  private func state(of items: [CleanupItem]) -> CleanupCheckState {
    let count = items.reduce(0) { $0 + (selection.contains($1.id) ? 1 : 0) }
    return count == 0 ? .off : (count == items.count ? .on : .mixed)
  }

  private func toggle(_ items: [CleanupItem]) {
    let ids = items.map(\.id)
    if state(of: items) == .on { selection.subtract(ids) } else { selection.formUnion(ids) }
    selectionRevision &+= 1
    review = nil
  }

  private func toggleExpanded(_ id: String) {
    withAnimation(AIMMotion.move(reduceMotion: reduceMotion)) {
      var next = expanded
      if next.contains(id) { next.remove(id) } else { next.insert(id) }
      expanded = next
    }
  }

  private func defaultSelection() -> Set<String> {
    Set((scan?.categories ?? []).filter(\.preselected).flatMap { visible($0) }.map(\.id))
  }

  private func resetSelection() {
    selection = defaultSelection()
    selectionRevision &+= 1
    useSamples = false
    clearIndex = false
    review = nil
  }

  // MARK: Actions

  private func reload() async {
    guard let source else { return }
    loading = true
    defer { loading = false }
    error = nil
    review = nil
    do {
      let next = try await model.cleanupScan(source)
      trash = try await model.cleanupTrash(source)
      samples = source.tool == .codex ? try await model.cleanupSamples() : []
      sizes = source.tool == .codex ? await model.rebuildableCacheSizes() : RebuildableCacheSizes(usageBytes: 0, conversationBytes: 0)
      anchor = Date()
      scan = next
      scannedSourceID = source.id
      resetSelection()
    } catch { self.error = error.localizedDescription }
  }

  private func makeReview() async {
    guard let source else { return }
    loading = true
    defer { loading = false }
    error = nil
    do {
      let items = selectedItems
      let plan = items.isEmpty ? nil : try await model.reviewCleanup(source, items)
      let byID = Dictionary(uniqueKeysWithValues: (scan?.categories ?? []).flatMap { category in
        category.items.map { ($0.id, category) }
      })
      let groups = Dictionary(grouping: items, by: { byID[$0.id]?.id ?? "" }).compactMap { key, values -> CleanupReview.Group? in
        guard let title = (scan?.categories ?? []).first(where: { $0.id == key })?.title else { return nil }
        return CleanupReview.Group(id: key, title: title, count: values.count, bytes: values.reduce(0) { $0 + $1.bytes })
      }.sorted { $0.bytes > $1.bytes }
      showReviewItems = false
      review = CleanupReview(
        plan: plan, groups: groups, samples: useSamples ? visibleSamples : [], clearIndex: clearIndex)
    } catch { self.error = error.localizedDescription }
  }

  private func apply() async {
    guard let source, let review else { return }
    do {
      try await model.applyCleanup(source, plan: review.plan, samples: review.samples, clearIndex: review.clearIndex)
      self.review = nil
      await reload()
    } catch {
      self.review = nil
      await reload()
      self.error = "\(error.localizedDescription) Review again. Items already in the trash can be restored."
    }
  }

  private func restore(_ batch: ConversationCleanupBatch) async {
    guard let source else { return }
    do { try await model.restoreCleanup(source, batch.id); await reload() }
    catch { self.error = error.localizedDescription }
  }

  private func remove(_ batch: ConversationCleanupBatch) async {
    guard let source else { return }
    removingBatch = nil
    do { try await model.emptyCleanup(source, batch.id); await reload() }
    catch { self.error = error.localizedDescription }
  }
}
