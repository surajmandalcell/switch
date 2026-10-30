import AIManagerCore
import AppKit
import SwiftUI

#if !AI_MANAGER_PREVIEW
#error("ConversationsCheck requires AI_MANAGER_PREVIEW")
#endif

// MARK: - Fixtures

/// Threads and long messages built in memory: code blocks of hundreds of lines, very long lines,
/// nested fences, long Markdown answers, and tool output.
struct SyntheticChatProvider: ChatHistoryProviding {
  let threads: [ChatThreadSummary]
  let messages: [String: [ChatMessage]]

  func refresh(query: String) async throws -> ChatHistorySnapshot { snapshot(query) }
  func search(query: String) async -> ChatHistorySnapshot { snapshot(query) }
  func clearCache() async throws {}

  func detail(for id: String) async throws -> ChatThreadDetail? {
    guard let thread = threads.first(where: { $0.id == id }) else { return nil }
    let all = messages[id] ?? []
    return ChatThreadDetail(thread: thread, messages: all, omittedMessageCount: 0, matchingMessageCount: all.count)
  }

  private func snapshot(_ query: String) -> ChatHistorySnapshot {
    let terms = query.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
    let matches = terms.isEmpty ? threads : threads.filter { thread in
      let text = (thread.title + " " + thread.preview).lowercased()
      return terms.allSatisfy(text.contains)
    }
    return ChatHistorySnapshot(
      threads: matches, libraryRevision: 1, totalThreadCount: threads.count, matchingThreadCount: matches.count)
  }

  /// Conversation 3 is the one the restart check scrolls a quarter of the way, so it must outgrow the
  /// tallest window (900 pt) by a wide margin. The others stay short.
  static func messageCount(of index: Int) -> Int { index == 3 ? 24 : 8 }

  static func thread(_ index: Int, title: String, messages: Int, tokens: Int64? = 48_200) -> ChatThreadSummary {
    ChatThreadSummary(
      id: "synthetic-\(index)", threadID: "synthetic-\(index)", title: title,
      preview: "A synthetic conversation used to check the reader.",
      workingDirectory: "/Projects/Switch", updatedAt: Date(timeIntervalSinceNow: -Double(index) * 600),
      archived: false, messageCount: messages, fileByteCount: Int64(messages) * 4_000,
      source: URL(fileURLWithPath: "/Synthetic/\(index).jsonl"), unreadableRecordCount: 0, totalTokens: tokens)
  }

  /// One long conversation with every shape of message that used to clip, plus many small threads.
  static func stress(threadCount: Int) -> SyntheticChatProvider {
    var threads = [
      thread(
        0, title: "Fix the clipped code blocks and the overlapping message headers in the Conversations reader",
        messages: 60)
    ]
    for index in 1..<max(threadCount, 2) {
      threads.append(thread(
        index, title: "Synthetic conversation \(String(format: "%04d", index))", messages: messageCount(of: index)))
    }
    let base = Date(timeIntervalSinceNow: -86_400)
    var long: [ChatMessage] = []
    for round in 0..<10 {
      func add(_ role: ChatMessageRole, _ text: String) {
        long.append(ChatMessage(
          id: "synthetic-0#\(long.count)", role: role, text: text,
          timestamp: base.addingTimeInterval(Double(long.count) * 37)))
      }
      add(.user, "Round \(round): the code blocks are cut off and some responses end half way. " + sentence(7))
      add(.assistant, markdownAnswer(round))
      add(.tool, (0..<(round % 2 == 0 ? 220 : 12)).map {
        "tool output line \($0): " + String(repeating: "result ", count: 3 + $0 % 17)
      }.joined(separator: "\n"))
      // A mid-size answer: short enough to show in full, with a heading, a list, and a code block.
      add(.assistant, """
        ### Quick fix \(round)

        The row height must follow the content. \(sentence(12))

        ```swift
        \(codeLines(count: 9, longEvery: 4))
        ```

        1. Measure the row at the real width
        2. Measure it again when the text changes
        """)
      add(.assistant, "```swift\n" + codeLines(count: 320, longEvery: 9) + "\n```\nThat is the whole function.")
      add(.other, "Context compacted after \(round * 1_000 + 800) tokens.")
    }
    var byID: [String: [ChatMessage]] = ["synthetic-0": long]
    for index in 1..<max(threadCount, 2) {
      byID["synthetic-\(index)"] = (0..<messageCount(of: index)).map {
        ChatMessage(
          id: "synthetic-\(index)#\($0)", role: $0 % 2 == 0 ? .user : .assistant,
          text: sentence(4 + $0), timestamp: base.addingTimeInterval(Double($0) * 40))
      }
    }
    return SyntheticChatProvider(threads: threads, messages: byID)
  }

  static func sentence(_ words: Int) -> String {
    let pool = ["the", "reader", "keeps", "every", "message", "visible", "without", "clipping", "its", "text",
      "or", "overlapping", "the", "next", "row", "even", "when", "the", "window", "is", "narrow"]
    return (0..<(words * 3)).map { pool[($0 * 7 + words) % pool.count] }.joined(separator: " ") + "."
  }

  static func codeLines(count: Int, longEvery: Int) -> String {
    (0..<count).map { line in
      if line % longEvery == 0 {
        return "    let value\(line) = compute(" + (0..<14).map { "argument\($0): \(line * $0)" }.joined(separator: ", ") + ") // a very long line that needs to wrap"
      }
      return "  func step\(line)(_ input: Int) -> Int { return input &+ \(line) }"
    }.joined(separator: "\n")
  }

  static func markdownAnswer(_ round: Int) -> String {
    let paragraphs = (0..<(6 + round)).map { "Paragraph \($0): " + sentence(30) }.joined(separator: "\n\n")
    return """
      ## Plan for round \(round)

      \(paragraphs)

      - First item with **bold** text and `inline code` that stays readable
      - Second item: \(sentence(18))
      - Third item

      ```bash
      \(codeLines(count: 40, longEvery: 5))
      ```

      A nested fence inside a longer fence:

      ````markdown
      ```swift
      let nested = true
      ```
      ````

      ```text
      \(String(repeating: "x", count: 2_400))
      ```
      """
  }
}

struct NoChatMonitor: ChatHistoryMonitoring {
  func changes() -> AsyncStream<Void> { AsyncStream { _ in } }
}

/// The owner's real Codex library, read only: sessions are indexed into a temporary cache.
struct RealChatProvider: ChatHistoryProviding {
  let index: ChatHistoryIndex
  func refresh(query: String) async throws -> ChatHistorySnapshot { try await index.refresh(query: query) }
  func search(query: String) async -> ChatHistorySnapshot { await index.search(query: query) }
  func detail(for id: String) async throws -> ChatThreadDetail? { try await index.detail(for: id) }
  func page(for id: String, offset: Int, query: String, filter: ChatMessageFilter) async throws -> ChatThreadDetail? {
    try await index.detail(for: id, offset: offset, query: query, filter: filter)
  }
  func clearCache() async throws { try await index.clearCache() }
}

// MARK: - Check

/// The window's root hosting view, counting its layout passes: the window-level measure of the page cache
/// (`AppKitPlatformViewHost.fittingSize`) runs inside one, so layouts per scroll step show it.
final class CountingRootHost: NSHostingView<AnyView> {
  nonisolated(unsafe) static var layouts = 0
  override func layout() {
    Self.layouts += 1
    super.layout()
  }
}

private final class WheelTestDocument: NSView {
  override var isFlipped: Bool { true }
}

@MainActor enum ConversationsCheck {
  static var shotsDirectory: URL? {
    ProcessInfo.processInfo.environment["AI_MANAGER_CONV_SHOTS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
  }

  static func makeModel(provider: any ChatHistoryProviding, root: URL) -> AccountViewModel {
    let paths = ManagerPaths(
      applicationSupport: root.appending(path: "app"), defaultHome: root.appending(path: "home"),
      sharedRoot: root.appending(path: "home"), orcaAccountsRoot: root.appending(path: "orca"))
    return AccountViewModel(paths: paths, chatHistoryProvider: provider, chatHistoryMonitor: NoChatMonitor())
  }

  static func host(_ view: some View, size: NSSize, dark: Bool) -> (NSWindow, NSHostingView<AnyView>) {
    // The window applies the saved appearance, so a run picks its own (a contract run uses a temporary home).
    UserDefaults.standard.set(dark ? "dark" : "light", forKey: "windowAppearance")
    let hosting = CountingRootHost(rootView: AnyView(view.renderScaled()))
    hosting.sizingOptions = []
    let window = AIManagerWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.contentView = hosting
    hosting.frame = NSRect(origin: .zero, size: size)
    window.orderOut(nil)
    hosting.layoutSubtreeIfNeeded()
    return (window, hosting)
  }

  static func pause(_ milliseconds: Int) async {
    try? await Task.sleep(for: .milliseconds(milliseconds))
  }

  static func waitUntil(timeout: Double = 8, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      await pause(40)
    }
    return condition()
  }

  static func views(in root: NSView) -> [NSView] { [root] + root.subviews.flatMap { views(in: $0) } }

  static func save(_ view: NSView, name: String) {
    guard let directory = shotsDirectory else { return }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    if let data = RenderScale.png(of: view) { try? data.write(to: directory.appending(path: name + ".png")) }
  }

  /// Every realized message row must be as tall as its content needs, and rows must not overlap.
  static func auditRows(in root: NSView, label: String) -> [String] {
    var failures: [String] = []
    guard let table = views(in: root).compactMap({ $0 as? AIMVirtualTableView }).first else {
      return ["\(label): no message table"]
    }
    var previousMax: CGFloat = -1
    for row in 0..<table.numberOfRows {
      let rect = table.rect(ofRow: row)
      if rect.minY < previousMax - 0.5 { failures.append("\(label): row \(row) overlaps the row above") }
      previousMax = rect.maxY
    }
    let visible = table.rows(in: table.visibleRect)
    for row in visible.location..<(visible.location + visible.length) {
      guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false),
        let hosting = cell.subviews.first as? NSHostingView<AnyView>
      else { continue }
      let rect = table.rect(ofRow: row)
      let needed = ceil(NSHostingController(rootView: hosting.rootView)
        .sizeThatFits(in: CGSize(width: rect.width, height: .greatestFiniteMagnitude)).height)
      if rect.height < needed - 0.5 {
        failures.append("\(label): row \(row) is \(Int(rect.height)) pt tall but its content needs \(Int(needed)) pt (clipped)")
      }
      if rect.height > needed + 24 {
        failures.append("\(label): row \(row) is \(Int(rect.height)) pt tall for \(Int(needed)) pt of content (gap)")
      }
    }
    return failures
  }

  /// Scrolls the message table top to bottom in steps and audits every screenful.
  static func scrollAndAudit(window: NSWindow, root: NSView, label: String, shot: String?) async -> [String] {
    var failures: [String] = []
    guard let table = views(in: root).compactMap({ $0 as? AIMVirtualTableView }).first,
      let scroll = table.enclosingScrollView
    else { return ["\(label): no message table"] }
    var offset: CGFloat = 0
    var step = 0
    while true {
      scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
      scroll.reflectScrolledClipView(scroll.contentView)
      root.layoutSubtreeIfNeeded()
      await pause(120)
      root.layoutSubtreeIfNeeded()
      failures += auditRows(in: root, label: "\(label) y=\(Int(offset))")
      if let shot, [0, 3, 8].contains(step) { save(root, name: "\(shot)-\(step)") }
      step += 1
      let travel = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
      if offset >= travel - 0.5 || step > 120 { break }
      offset = min(travel, offset + scroll.contentView.bounds.height * 0.6)
    }
    return failures
  }

  /// Short overflow must still scroll from either end, including when it is smaller than one wheel step.
  static func wheelBoundaryFailures() async -> [String] {
    let scroll = AIMOwnedScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
    let document = WheelTestDocument()
    scroll.documentView = document
    let window = NSWindow(contentRect: scroll.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = scroll
    window.orderOut(nil)
    defer { window.close() }
    var failures: [String] = []
    for travel in [10.0, 59.0, 120.0] {
      document.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: scroll.contentSize.height + travel)
      scroll.layoutSubtreeIfNeeded()
      for top in [0.0, travel] {
        scroll.contentView.scroll(to: NSPoint(x: 0, y: top))
        scroll.reflectScrolledClipView(scroll.contentView)
        failures += await wheelFailures(window: window, label: "Boundary travel=\(travel) top=\(top)")
      }
    }
    return failures
  }

  /// A classic mouse wheel (line units) and a pixel wheel, over the middle and over the trailing gutter
  /// of every scrollable area in the window, must move that area. The event is routed as the window
  /// does: hit-test the point, then send it to that view (NSWindow.sendEvent drops a windowless event).
  /// The window is parked at the screen origin so the CGEvent's screen point and window point agree.
  static func wheelFailures(window: NSWindow, label: String) async -> [String] {
    guard let root = window.contentView, let frame = root.superview else { return ["\(label) wheel: no window"] }
    let saved = window.frame.origin
    window.setFrameOrigin(.zero)
    defer { window.setFrameOrigin(saved) }
    // Moving between screens and attaching a cached page can queue a new viewport and row layout.
    var previous: [NSRect] = []
    var stableTurns = 0
    let ready = await waitUntil(timeout: 2) {
      root.layoutSubtreeIfNeeded()
      let geometry = views(in: root).compactMap { $0 as? NSScrollView }.flatMap {
        [$0.frame, $0.contentView.bounds, $0.documentView?.frame ?? .zero]
      }
      stableTurns = geometry == previous ? stableTurns + 1 : 0
      previous = geometry
      return stableTurns >= 2
    }
    guard ready else { return ["\(label) wheel: scroll layout did not settle"] }
    let scrolls = views(in: root).compactMap { $0 as? NSScrollView }.filter {
      ($0.documentView?.frame.height ?? 0) > $0.contentView.bounds.height + 1 && $0.frame.height > 60
    }
    if scrolls.isEmpty { return [] }
    let screenHeight = NSScreen.screens.first?.frame.height ?? 0
    var failures: [String] = []
    for scroll in scrolls {
      for (spot, x) in [("middle", scroll.bounds.midX), ("gutter", scroll.bounds.maxX - 8)] {
        for (unit, amount) in [(CGScrollEventUnit.line, Int32(3)), (.pixel, 40)] {
          let top = scroll.contentView.bounds.minY
          let travel = (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height
          // Pick the direction with more room, including a document less than 60 pt taller than its viewport.
          let sign: Int32 = top > travel / 2 ? 1 : -1
          let point = scroll.convert(NSPoint(x: x, y: scroll.bounds.midY), to: nil)
          guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: unit, wheelCount: 1, wheel1: amount * sign, wheel2: 0, wheel3: 0)
          else { failures.append("\(label) wheel: could not create its event"); continue }
          cg.location = CGPoint(x: point.x, y: screenHeight - point.y)
          guard let event = NSEvent(cgEvent: cg), let hit = frame.hitTest(event.locationInWindow) else {
            failures.append("\(label) wheel: no event target over the \(spot)"); continue
          }
          if CommandLine.arguments.contains("--conversations-wheel-only"), spot == "middle", unit == .line {
            print("WHEEL_BEFORE_EVENT spot=\(spot) unit=\(unit) top=\(top) travel=\(travel) sign=\(sign) attached=\(scroll.window === window)")
          }
          // The main window routes a wheel in sendEvent, before SwiftUI sees it; any other window by hit test.
          if window is AIManagerWindow { window.sendEvent(event) } else { hit.scrollWheel(with: event) }
          _ = await waitUntil(timeout: 2) { scroll.contentView.bounds.minY != top }
          if scroll.contentView.bounds.minY == top {
            failures.append("\(label) wheel: a \(unit == .line ? "line" : "pixel") wheel over the \(spot) of the "
              + "\(Int(scroll.frame.width))x\(Int(scroll.frame.height)) area (\(type(of: hit))) did not scroll it")
            print("WHEEL_STATE top=\(top) travel=\(travel) sign=\(sign) document=\(scroll.documentView?.frame ?? .zero) clip=\(scroll.contentView.bounds) attached=\(scroll.window === window) point=\(event.locationInWindow) target=\(AIMHostingView.visible(in: root).flatMap { AIMHostingView.smallestScrollView(in: $0, at: event.locationInWindow) } === scroll)")
          }
          scroll.contentView.scroll(to: NSPoint(x: 0, y: top))
          scroll.reflectScrolledClipView(scroll.contentView)
        }
      }
    }
    // Over the page's fixed header (off every scroll view) a wheel scrolls the page.
    if window is AIManagerWindow, let page = AIMHostingView.pageScrollView(in: root),
       (page.documentView?.frame.height ?? 0) > page.contentView.bounds.height + 1 {
      let top = page.contentView.bounds.minY
      let spot = root.convert(
        NSPoint(x: page.convert(NSPoint(x: page.bounds.midX, y: 0), to: root).x,
                y: root.isFlipped ? AIMTheme.topBarHeight / 2 : root.bounds.height - AIMTheme.topBarHeight / 2), to: nil)
      if page.bounds.contains(page.convert(spot, from: nil)) {
        failures.append("\(label) wheel: the header spot lies inside the page scroll view")
      }
      let travel = (page.documentView?.frame.height ?? 0) - page.contentView.bounds.height
      let sign: Int32 = top > travel / 2 ? 1 : -1
      if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 40 * sign, wheel2: 0, wheel3: 0) {
        cg.location = CGPoint(x: spot.x, y: screenHeight - spot.y)
        if let event = NSEvent(cgEvent: cg) {
          window.sendEvent(event)
          _ = await waitUntil(timeout: 2) { page.contentView.bounds.minY != top }
          if page.contentView.bounds.minY == top { failures.append("\(label) wheel: a wheel over the fixed header did not scroll the page") }
          page.contentView.scroll(to: NSPoint(x: 0, y: top))
          page.reflectScrolledClipView(page.contentView)
        }
      }
    }
    return failures
  }

  /// Main-thread cost of one scroll step (40 pt) of a page: scroll, let queued work run, lay out, and
  /// (second pass) draw the window content. Prints SCROLLCOST lines, two rounds for Accounts and Overview.
  static func scrollCost() async -> [String] {
    var failures: [String] = []
    for page in [AIManagerPage.accounts, .overview] {
      for round in 0..<2 {
        let model = AccountViewModel(scenario: .historyStress)
        model.installScaleFixture(accountCount: 60, activityDays: 365)
        let (window, hosting) = host(
          AccountWindow(model: model, initialPageIndex: AIManagerPage.allCases.firstIndex(of: page) ?? 0),
          size: NSSize(width: 1200, height: 900), dark: false)
        await pause(1_200)
        guard let scroll = AIMHostingView.pageScrollView(in: hosting) else {
          failures.append("\(page.rawValue): no page scroll view"); window.close(); continue
        }
        // `--scroll-poke`: also mark the page cache's own host stale on every step, as the live window does
        // (the wheel trace shows it on Accounts through a transform update). The harness window is
        // ordered out, where that host does not invalidate by itself.
        let cacheHost = views(in: hosting).first { $0 is AIMHostingView && !($0.superview is NSClipView) }
        let poke = CommandLine.arguments.contains("--scroll-poke")
        let travel = (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height
        for draw in [false, true] {
          var times: [Double] = []
          let steps = Int(PreviewArguments.value("scroll-steps") ?? "") ?? 60
          let stoppedBefore = AIMConstraintNoticeStop.stopped
          let invalidBefore = AIMHostingView.constraintInvalidations, layoutBefore = AIMHostingView.layoutCalls
          let cacheInvalidBefore = AIMHostingView.cacheHostInvalidations, cacheLayoutBefore = AIMHostingView.cacheHostLayouts
          let rootBefore = CountingRootHost.layouts
          for step in 0..<steps {
            let start = CFAbsoluteTimeGetCurrent()
            // Down, then back up when the page ends, so a long run keeps moving.
            let along = 40 * CGFloat(step + 1), back = travel > 0 ? along.truncatingRemainder(dividingBy: 2 * travel) : 0
            scroll.contentView.scroll(to: NSPoint(x: 0, y: back > travel ? 2 * travel - back : back))
            scroll.reflectScrolledClipView(scroll.contentView)
            RunLoop.main.run(until: Date().addingTimeInterval(0.002))
            if poke { cacheHost?.needsUpdateConstraints = true }
            hosting.layoutSubtreeIfNeeded()
            if draw, let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
              hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            }
            times.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
          }
          times.sort()
          // Per step: constraint notices stopped at the page scroll view and at the page cache; the hosts'
          // own invalidations and layouts (6 and 3 without the stop); and the window root's layouts, which
          // hold the window-level measure of the page cache (0 when nothing reaches SwiftUI's host).
          func stopped(_ kind: String) -> Double {
            Double(AIMConstraintNoticeStop.stopped[kind, default: 0] - stoppedBefore[kind, default: 0]) / Double(steps)
          }
          print(String(format: "SCROLLCOST round=%d page=%@ draw=%@ median=%.2f p90=%.2f ms stoppedPage/step=%.2f stoppedCache/step=%.2f invalidate/step=%.2f hostLayout/step=%.2f cacheInvalidate/step=%.2f cacheLayout/step=%.2f rootLayout/step=%.2f",
            round, page.rawValue, draw ? "yes" : "no", times[times.count / 2], times[times.count * 9 / 10],
            stopped("AIMPageScrollView"), stopped("Container"),
            Double(AIMHostingView.constraintInvalidations - invalidBefore) / Double(steps),
            Double(AIMHostingView.layoutCalls - layoutBefore) / Double(steps),
            Double(AIMHostingView.cacheHostInvalidations - cacheInvalidBefore) / Double(steps),
            Double(AIMHostingView.cacheHostLayouts - cacheLayoutBefore) / Double(steps),
            Double(CountingRootHost.layouts - rootBefore) / Double(steps)))
          scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
          scroll.reflectScrolledClipView(scroll.contentView)
          await pause(200)        }
        // After many scroll frames the page host still redraws on a state change (stopping the constraint
        // notice must not starve its updates): another selection moves the focused card.
        if page == .accounts, let other = model.status?.accounts.map(\.id).first(where: { $0 != model.selectedAccountID }) {
          func snapshot() -> Data? {
            guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            return bitmap.tiffRepresentation
          }
          let before = snapshot()
          model.selectedAccountID = other
          await pause(500)
          if snapshot() == before { failures.append("Accounts: after scrolling, a selection change did not redraw the page host") }
        }
        window.close()
      }
    }
    return failures
  }

  /// Time from a page selection to its first rendered frame, for every page, against many
  /// accounts, a year of daily activity, and thousands of conversations. Returns failures for
  /// first visits above 150 ms, warm medians above 50 ms, or warm frames above 80 ms.
  /// Environment trackers and the process footprint, read with `heap` on this process.
  static func memoryReading() -> (tracked: Int, footprint: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/heap")
    process.arguments = ["\(getpid())"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    guard (try? process.run()) != nil else { return (-1, "?") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    var tracked = 0
    var footprint = "?"
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
      if line.contains("Physical footprint:") { footprint = line.split(separator: " ").last.map(String.init) ?? "?" }
      if line.contains("_ContiguousArrayStorage<SwiftUI.(AnyTrackedValue") {
        tracked += Int(line.split(separator: " ", omittingEmptySubsequences: true).dropFirst().first ?? "") ?? 0
      }
    }
    return (tracked, footprint)
  }

  static func memoryCheck() async -> [String] {
    let model = AccountViewModel(scenario: .historyStress)
    let (window, hosting) = host(AccountWindow(model: model, initialPageIndex: 0),
      size: NSSize(width: 1200, height: 900), dark: false)
    func select(_ page: AIManagerPage) async {
      NotificationCenter.default.post(name: AIManagerNavigation.request, object: page)
      _ = await waitUntil { AIMPlace.visiblePage == page }
      hosting.layoutSubtreeIfNeeded()
      await pause(300)
    }
    func report(_ stage: String) {
      let reading = memoryReading()
      print("MEMORY \(stage) tracked=\(reading.tracked) footprint=\(reading.footprint)")
    }
    var failures: [String] = []
    await pause(1_500)
    for page in AIManagerPage.allCases { await select(page) }
    await pause(2_000)
    let warm = memoryReading().tracked
    print("MEMORY warm tracked=\(warm)")
    if warm < 0 { failures.append("heap could not read this process") }
    let cycles = Int(PreviewArguments.value("memory-cycles") ?? "") ?? 200
    for page in [AIManagerPage.overview, .accounts, .conversations, .maintenance, .settings] {
      await select(page)
      for _ in 0..<cycles {
        model.objectWillChange.send()
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.002))
        hosting.layoutSubtreeIfNeeded()
      }
      let reading = memoryReading()
      print("MEMORY \(page.rawValue) +\(cycles) updates tracked=\(reading.tracked) footprint=\(reading.footprint)")
      // A page host that gets the outer EnvironmentValues grew by about 120 KB per update here.
      if reading.tracked - warm > 1_000_000 {
        failures.append("\(page.rawValue): environment trackers grew \((reading.tracked - warm) / 1_000) KB in \(cycles) updates")
      }
    }
    // A change the page cache sees (busy, an error, the search) builds the page's root again.
    await select(.accounts)
    let before = memoryReading().tracked
    for _ in 0..<cycles {
      model.isBusy.toggle()
      RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.002))
      hosting.layoutSubtreeIfNeeded()
    }
    model.isBusy = false
    let rebuilt = memoryReading()
    print("MEMORY Accounts +\(cycles) rebuilds tracked=\(rebuilt.tracked) footprint=\(rebuilt.footprint)")
    if rebuilt.tracked - before > 1_000_000 {
      failures.append("Accounts: environment trackers grew \((rebuilt.tracked - before) / 1_000) KB in \(cycles) page rebuilds")
    }
    window.close()

    // Closing the main window, or hiding it to the menu bar, hands it back so its pages can be freed.
    let placement = UserDefaults(suiteName: "switch-memory-\(UUID().uuidString)") ?? .standard
    for hides in [false, true] {
      UserDefaults.standard.set(hides, forKey: AIManagerWindowBehavior.minimizeToTrayKey)
      var controller: AIManagerWindowController<AccountWindow>? = AIManagerWindowController(
        title: "Memory", rootView: AccountWindow(model: AccountViewModel(scenario: .demo)), placementDefaults: placement)
      weak var released = controller
      var hidden = false
      controller?.onHide = { hidden = true }
      controller?.window?.contentView?.layoutSubtreeIfNeeded()
      // The app posts a page request right after building a new window; it must arrive.
      let target: AIManagerPage = hides ? .settings : .maintenance
      NotificationCenter.default.post(name: AIManagerNavigation.request, object: target)
      if !(await waitUntil(timeout: 3) {
        controller?.window?.contentView?.layoutSubtreeIfNeeded()
        return AIMPlace.visiblePage == target
      }) { failures.append("a new main window misses the page request posted after it is built") }
      if hides { controller?.minimize() } else { controller?.window?.close() }
      controller = nil
      await pause(300)
      if !hidden { failures.append(hides ? "hiding to the menu bar does not hand the window back" : "closing does not hand the window back") }
      if released != nil { failures.append("the main window stays in memory after \(hides ? "hiding" : "closing")") }
    }
    UserDefaults.standard.removeObject(forKey: AIManagerWindowBehavior.minimizeToTrayKey)
    return failures
  }

  static func pageSwitchTimes() async -> [String] {
    var failures: [String] = []
    let model = AccountViewModel(scenario: .historyStress)
    model.installScaleFixture(accountCount: 60, activityDays: 365)
    let (window, hosting) = host(
      AccountWindow(model: model, initialPageIndex: 0), size: NSSize(width: 1200, height: 900), dark: false)
    await pause(1_000)
    // `--profile-page=Settings` alternates that page with Overview for 40 switches, for `sample`.
    if let name = PreviewArguments.value("profile-page"), let target = AIManagerPage(rawValue: name) {
      for _ in 0..<40 {
        for page in [target, AIManagerPage.overview] {
          NotificationCenter.default.post(name: AIManagerNavigation.request, object: page)
          let start = CFAbsoluteTimeGetCurrent()
          while AIMPlace.visiblePage != page, CFAbsoluteTimeGetCurrent() - start < 3 {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.001))
          }
          hosting.layoutSubtreeIfNeeded()
          if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
          }
          await pause(30)
        }
      }
      window.close()
      return []
    }
    var cold: [AIManagerPage: Double] = [:]
    var warm: [AIManagerPage: [Double]] = [:]
    var parts: [AIManagerPage: (state: Double, layout: Double, render: Double)] = [:]
    let order: [AIManagerPage] = [.accounts, .settings, .maintenance, .conversations, .overview]
    for round in 0..<4 {
      for page in order {
        let start = CFAbsoluteTimeGetCurrent()
        NotificationCenter.default.post(name: AIManagerNavigation.request, object: page)
        while AIMPlace.visiblePage != page, CFAbsoluteTimeGetCurrent() - start < 3 {
          RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.001))
        }
        let selected = CFAbsoluteTimeGetCurrent()
        hosting.layoutSubtreeIfNeeded()
        let laidOut = CFAbsoluteTimeGetCurrent()
        if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
          hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        } else {
          failures.append("\(page.rawValue): no full-frame bitmap")
        }
        let milliseconds = (CFAbsoluteTimeGetCurrent() - start) * 1_000
        if round == 0 { cold[page] = milliseconds } else { warm[page, default: []].append(milliseconds) }
        if round == 1 {
          parts[page] = (state: (selected - start) * 1_000, layout: (laidOut - selected) * 1_000,
            render: (CFAbsoluteTimeGetCurrent() - laidOut) * 1_000)
        }
        await pause(900)
      }
    }
    for page in order {
      let worst = warm[page]?.max() ?? 0
      let median = warm[page].map { $0.sorted()[$0.count / 2] } ?? 0
      let split = parts[page].map { String(format: " [state %.0f, layout %.0f, render %.0f]", $0.state, $0.layout, $0.render) } ?? ""
      print(String(format: "PAGE_SWITCH %@ first=%.0f ms median=%.0f ms worst=%.0f ms", page.rawValue, cold[page] ?? 0, median, worst) + split)
      // A page's cards are a second hosting graph in an AppKit scroll view (about 3 ms per switch),
      // and a loaded Mac moves a median by up to 10 ms.
      if worst > 80 || median > 60 || (cold[page] ?? 0) > 150 {
        failures.append("\(page.rawValue) exceeds first 150 / median 60 / worst 80 ms")
      }
    }
    window.close()
    return failures + (await sidebarSyncCheck())
  }

  /// After every sidebar selection, each rendered frame shows the new page with the new highlight, or
  /// the old page with the old highlight, never a mix. The highlight row is read from pixels: the
  /// row's open area against the sidebar padding beside it.
  static func sidebarSyncCheck() async -> [String] {
    var failures: [String] = []
    let model = AccountViewModel(scenario: .historyStress)
    let (window, hosting) = host(
      AccountWindow(model: model, initialPageIndex: 0), size: NSSize(width: 1200, height: 900), dark: false)
    await pause(1_000)
    let pages = AIManagerPage.allCases
    func shownPage() -> AIManagerPage? {
      views(in: hosting).lazy.compactMap { ($0 as? AIMVisitedPageHost.Container)?.current }.first
    }
    func highlighted() -> [AIManagerPage] {
      guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return [] }
      hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
      let scale = CGFloat(bitmap.pixelsWide) / hosting.bounds.width
      func pixel(_ x: CGFloat, _ y: CGFloat) -> NSColor {
        bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.deviceRGB) ?? .clear
      }
      return pages.enumerated().filter { index, _ in
        let y = AIMTheme.topBarHeight + 2 + CGFloat(index) * 34 + 16
        let row = pixel(AIMTheme.sidebarWidth - 24, y), side = pixel(4, y)
        let gap = abs(row.redComponent - side.redComponent) + abs(row.greenComponent - side.greenComponent)
          + abs(row.blueComponent - side.blueComponent)
        return gap > 0.02
      }.map(\.element)
    }
    let route: [AIManagerPage] = [.settings, .conversations, .accounts, .maintenance, .overview, .conversations, .settings]
    for target in route + route {
      let before = shownPage()
      NotificationCenter.default.post(name: AIManagerNavigation.request, object: target)
      let start = CFAbsoluteTimeGetCurrent()
      var frames = 0
      var settled = false
      while CFAbsoluteTimeGetCurrent() - start < 1 {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.004))
        let page = shownPage(), marked = highlighted()
        frames += 1
        if page != nil, marked != [page!] {
          failures.append("sidebar -> \(target.rawValue): frame \(frames) shows page \(page!.rawValue) with highlight \(marked.map(\.rawValue))")
          break
        }
        if page == target, marked == [target], frames > 2 { settled = true; break }
      }
      if !settled && failures.isEmpty { failures.append("sidebar -> \(target.rawValue): never settled (from \(before?.rawValue ?? "none"))") }
      if !failures.isEmpty { break }
      await pause(200)
    }
    window.close()
    return failures
  }

  /// A restart: the second window opens the same conversation, with the same filter, query and
  /// scroll place, as the first one left.
  static func restoreCheck(root: URL) async -> [String] {
    var failures: [String] = []
    for key in [ChatPlace.selectedKey, ChatPlace.anchorKey, ChatPlace.messageQueryKey] {
      UserDefaults.standard.removeObject(forKey: key)
    }
    func open(_ tag: String) async -> (NSWindow, NSHostingView<AnyView>, AccountViewModel) {
      let model = makeModel(provider: SyntheticChatProvider.stress(threadCount: 40), root: root.appending(path: "restore"))
      let (window, hosting) = host(
        AccountWindow(model: model, initialPageIndex: 4), size: NSSize(width: 1200, height: 900), dark: false)
      _ = await waitUntil { model.selectedChat != nil && !model.isChatLoading }
      await pause(500)
      hosting.layoutSubtreeIfNeeded()
      return (window, hosting, model)
    }
    // The row at the top of the view: its index and how far the view sits below its top edge.
    func topRow(_ table: NSTableView) -> (row: Int, inset: CGFloat) {
      let y = table.enclosingScrollView?.contentView.bounds.minY ?? 0
      let row = table.row(at: NSPoint(x: 1, y: y + 1))
      return (row, row >= 0 ? y - table.rect(ofRow: row).minY : 0)
    }
    let (first, firstView, firstModel) = await open("first")
    await firstModel.selectChat(firstModel.chatHistory.threads[3].id)
    _ = await waitUntil { firstModel.selectedChat?.thread.id == firstModel.chatHistory.threads[3].id && !firstModel.isChatLoading }
    await pause(500)
    firstView.layoutSubtreeIfNeeded()
    guard let table = views(in: firstView).compactMap({ $0 as? AIMVirtualTableView }).first,
      let scroll = table.enclosingScrollView
    else { return ["restore: no message table"] }
    let target = max(0, (scroll.documentView?.frame.height ?? 0) / 4)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: target))
    scroll.reflectScrolledClipView(scroll.contentView)
    firstView.layoutSubtreeIfNeeded()
    await pause(800)
    let saved = topRow(table)
    let chosen = firstModel.selectedChatID
    first.close()
    let (second, secondView, secondModel) = await open("second")
    await pause(800)
    secondView.layoutSubtreeIfNeeded()
    if secondModel.selectedChatID != chosen { failures.append("restore: the selected conversation was not kept") }
    if let table = views(in: secondView).compactMap({ $0 as? AIMVirtualTableView }).first {
      let restored = topRow(table)
      if saved.row <= 0 || restored.row != saved.row || abs(restored.inset - saved.inset) > 40 {
        failures.append("restore: top row \(restored.row)+\(Int(restored.inset)) differs from \(saved.row)+\(Int(saved.inset))")
      }
    } else {
      failures.append("restore: no message table after the restart")
    }
    // Save the end of a long conversation, then resize while its restored rows settle.
    await secondModel.selectChat(secondModel.chatHistory.threads[0].id)
    _ = await waitUntil { secondModel.selectedChat?.thread.id == secondModel.chatHistory.threads[0].id && !secondModel.isChatLoading }
    await pause(800)
    secondView.layoutSubtreeIfNeeded()
    if let endTable = views(in: secondView).compactMap({ $0 as? AIMVirtualTableView }).first,
      let endScroll = endTable.enclosingScrollView {
      endScroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, endTable.frame.height - endScroll.contentView.bounds.height)))
      endScroll.reflectScrolledClipView(endScroll.contentView)
      let lastID = secondModel.selectedChat?.messages.last?.id
      if !(await waitUntil { ChatPlace.anchor(for: secondModel.selectedChatID)?.messageID == lastID }) {
        failures.append("restore end: the bottom did not save the last message (clip \(endScroll.contentView.bounds), table \(endTable.frame.height), last \(endTable.rect(ofRow: endTable.numberOfRows - 1).maxY), anchor \(ChatPlace.anchor(for: secondModel.selectedChatID)?.messageID ?? "none"), last ID \(lastID ?? "none"))")
      }
    } else { failures.append("restore end: no message table") }
    second.close()
    let (third, thirdView, _) = await open("end")
    for size in [NSSize(width: 1200, height: 800), NSSize(width: 1200, height: 900)] {
      third.setContentSize(size)
      thirdView.layoutSubtreeIfNeeded()
      await pause(800)
      thirdView.layoutSubtreeIfNeeded()
      if let endTable = views(in: thirdView).compactMap({ $0 as? AIMVirtualTableView }).first,
        let clip = endTable.enclosingScrollView?.contentView {
        if abs(clip.bounds.maxY - endTable.rect(ofRow: endTable.numberOfRows - 1).maxY) > 1 {
          failures.append("restore end: the last row is not pinned at \(Int(size.width)) x \(Int(size.height))")
        }
      } else { failures.append("restore end: no table after restart") }
    }
    third.close()
    // The other passes start from the first conversation again.
    for key in [ChatPlace.selectedKey, ChatPlace.anchorKey, ChatPlace.messageQueryKey] {
      UserDefaults.standard.removeObject(forKey: key)
    }
    return failures
  }

  static func restartCheck() async -> [String] {
    let root = FileManager.default.temporaryDirectory.appending(path: "switch-restart-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    return await restoreCheck(root: root)
  }

  static func roundTripCheck() async -> [String] {
    var failures: [String] = []
    for dark in [false, true] {
      let model = AccountViewModel(scenario: .historyStress)
      let (window, hosting) = host(AccountWindow(model: model, initialPageIndex: 0),
        size: NSSize(width: 1200, height: 900), dark: dark)
      func select(_ page: AIManagerPage) async {
        NotificationCenter.default.post(name: AIManagerNavigation.request, object: page)
        _ = await waitUntil { AIMPlace.visiblePage == page }
        hosting.layoutSubtreeIfNeeded()
        await pause(500)
        hosting.layoutSubtreeIfNeeded()
      }
      for page in AIManagerPage.allCases {
        let other: AIManagerPage = page == .overview ? .accounts : .overview
        await select(other)
        await select(page)
        guard let scroll = views(in: hosting).compactMap({ $0 as? NSScrollView }).max(by: {
          ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0)
        }) else { failures.append("round trip \(page.rawValue): no scroll view"); continue }
        let travel = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(travel, 120)))
        scroll.reflectScrolledClipView(scroll.contentView)
        await pause(500)
        let saved = scroll.contentView.bounds.minY
        await select(other)
        if scroll.window != nil { failures.append("round trip \(page.rawValue): hidden page remains attached") }
        await select(page)
        if scroll.window !== window || abs(scroll.contentView.bounds.minY - saved) > 1 {
          failures.append("round trip \(page.rawValue): the scroll view or its place changed (was \(saved), now \(scroll.contentView.bounds.minY), same window \(scroll.window === window), inset \(scroll.contentInsets.top))")
        }
        if let container = views(in: hosting).first(where: { $0.identifier?.rawValue == "visited-page-host" }),
          container.subviews.count != 1 { failures.append("round trip \(page.rawValue): more than one page is attached") }
        save(hosting, name: "roundtrip-\(page.rawValue.lowercased())-\(dark ? "dark" : "light")")
      }
      window.close()
    }
    return failures
  }

  static func run() async -> [String] {
    var failures: [String] = []
    let root = FileManager.default.temporaryDirectory.appending(path: "switch-conversations-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    failures += await restoreCheck(root: root)
    failures += await roundTripCheck()
    let real = ProcessInfo.processInfo.environment["AI_MANAGER_CONV_REAL_HOME"]
    for dark in [false, true] {
      for height in [900.0, 800.0] {
        let tag = "\(dark ? "dark" : "light")-\(Int(height))"
        let model = makeModel(provider: SyntheticChatProvider.stress(threadCount: 40), root: root.appending(path: tag))
        let (window, hosting) = host(
          AccountWindow(model: model, initialPageIndex: 4), size: NSSize(width: 1200, height: height), dark: dark)
        let ready = await waitUntil { model.selectedChat != nil && !model.isChatLoading }
        if !ready { failures.append("\(tag): the conversation did not open") }
        await pause(500)
        hosting.layoutSubtreeIfNeeded()
        failures += await scrollAndAudit(window: window, root: hosting, label: tag, shot: "conv-\(tag)")
        failures += await wheelFailures(window: window, label: "Conversations \(tag)")
        // The same page after a live height change, at the other height.
        let other = height == 900 ? 800.0 : 900.0
        window.setContentSize(NSSize(width: 1200, height: other))
        hosting.layoutSubtreeIfNeeded()
        await pause(300)
        failures += await scrollAndAudit(window: window, root: hosting, label: "\(tag)->\(Int(other))", shot: nil)
        window.close()
      }
    }
    if let real {
      let tag = "real"
      let index = ChatHistoryIndex(
        home: URL(fileURLWithPath: real), cacheFile: root.appending(path: "real-cache.json"))
      let model = makeModel(provider: RealChatProvider(index: index), root: root.appending(path: tag))
      let (window, hosting) = host(
        AccountWindow(model: model, initialPageIndex: 4), size: NSSize(width: 1200, height: 900), dark: false)
      _ = await waitUntil(timeout: 90) { model.chatHistory.totalThreadCount > 0 }
      // Walk the ten largest conversations.
      let largest = model.chatHistory.threads.sorted { $0.fileByteCount > $1.fileByteCount }.prefix(10)
      for (n, thread) in largest.enumerated() {
        await model.selectChat(thread.id)
        _ = await waitUntil { model.selectedChat?.thread.id == thread.id && !model.isChatLoading }
        await pause(500)
        failures += await scrollAndAudit(
          window: window, root: hosting, label: "real-\(n)", shot: n < 3 ? "conv-real-\(n)" : nil)
      }
      window.close()
    }
    return failures
  }
}
