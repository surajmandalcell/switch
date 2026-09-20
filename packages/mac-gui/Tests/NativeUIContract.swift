import AIManagerCore
import AppKit
import SwiftUI

struct AIManagerNativeViewSnapshot: Codable {
  let path: String
  let className: String
  let frameX: Double
  let frameY: Double
  let frameWidth: Double
  let frameHeight: Double
  let isFlipped: Bool
  let focusRingType: UInt
  let scrollStyle: String?
  let autohidesScrollers: Bool?
  let verticalScrollerClass: String?
}

private final class HoverTestEvent: NSEvent {
  let area: NSTrackingArea
  let eventType: NSEvent.EventType
  let location: NSPoint
  init(area: NSTrackingArea, type: NSEvent.EventType, location: NSPoint? = nil) {
    self.area = area
    self.eventType = type
    let view = area.owner as? NSView
    let bounds = view?.bounds ?? .zero
    let rect = area.rect.isEmpty ? bounds : area.rect.intersection(bounds)
    self.location = location ?? view?.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil) ?? .zero
    super.init()
  }
  @available(*, unavailable) required init?(coder: NSCoder) { nil }
  override var trackingArea: NSTrackingArea? { area }
  override var type: NSEvent.EventType { eventType }
  override var locationInWindow: NSPoint { location }
}

private final class PaginationTestDocument: NSView {
  override var isFlipped: Bool { true }
}

@MainActor
enum AIManagerNativeContract {
  static func hoverFeedbackFailures() async -> [String] {
    var failures: [String] = []
    let shared = AnyView(Button {} label: {
        Text("Range").frame(width: 140, height: 30).background(AIMTheme.control)
      }.buttonStyle(AIMPressButtonStyle()))
    var controls: [(String, AnyView, Bool)] = [
      ("Shared button", shared, true),
      ("Disabled shared button", AnyView(shared.disabled(true)), false),
      ("Action button", AnyView(AIMButton(title: "Hover test", action: {})), true),
      ("Cleanup time range", AnyView(CleanupRangeSelect(selection: .constant(.all), expanded: .constant(false))), true),
      ("Icon button", AnyView(AIMIconButton(icon: .refresh, label: "Hover test", action: {})), true),
      ("Disabled icon button", AnyView(AIMIconButton(icon: .refresh, label: "Hover test", disabled: true, action: {})), false),
    ]
    let hover = AIMSidebarHover()
    controls.append(("Rail button", AnyView(RailButton(icon: .settings, label: "Settings", active: false,
      sidebarHover: hover, hoverID: "Settings", action: {})), true))
    let model = AccountViewModel(scenario: .demo)
    if let account = model.status?.accounts.first {
      controls.append(("Account row", AnyView(Button {} label: {
        AccountListRow(account: account, selected: false, isDefault: false, sidebarHover: hover)
      }.buttonStyle(AIMPressButtonStyle())), true))
    } else { failures.append("Account hover fixture has no account") }
    for (name, control, enabled) in controls {
      failures.append(contentsOf: await hoverFeedbackFailures(name: name, control: control, enabled: enabled))
    }
    for opacity in [1.0, 0.65] {
      failures.append(contentsOf: await hoverTransitionFailures(surfaceOpacity: opacity))
    }
    return failures
  }

  private static func hoverTransitionFailures(surfaceOpacity: Double) async -> [String] {
    let hover = AIMSidebarHover()
    let dark = NSApp.windows.first?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let root = VStack(spacing: 0) {
      RailButton(icon: .account, label: "Accounts", active: false,
        sidebarHover: hover, hoverID: "Accounts", action: {})
      RailButton(icon: .settings, label: "Settings", active: false,
        sidebarHover: hover, hoverID: "Settings", action: {})
    }.background(AIMTheme.canvas)
      .background {
        AIMVisualEffect(material: .underWindowBackground, blendingMode: .behindWindow, darkMode: dark)
      }
      .environment(\.aimSurfaceOpacity, surfaceOpacity)
      .environment(\.colorScheme, dark ? .dark : .light).environment(\.aimDarkMode, dark)
    let host = NSHostingView(rootView: root)
    host.frame = NSRect(x: 0, y: 0, width: 48, height: 96)
    let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = host
    try? await Task.sleep(for: .milliseconds(100))
    func areas(at point: NSPoint) -> [NSTrackingArea] {
      host.layoutSubtreeIfNeeded()
      return views(in: host).flatMap { view -> [NSTrackingArea] in
        view.updateTrackingAreas()
        return view.trackingAreas.filter { area in
          let rect = area.rect.isEmpty ? view.bounds : area.rect.intersection(view.bounds)
          return view.convert(rect, to: nil).contains(point)
        }
      }
    }
    let first = host.convert(NSPoint(x: 24, y: host.isFlipped ? 24 : 72), to: nil)
    let second = host.convert(NSPoint(x: 24, y: host.isFlipped ? 72 : 24), to: nil)
    // The physical replay also crossed within a point of the shared row edge.
    let firstEdge = host.convert(NSPoint(x: 24, y: host.isFlipped ? 47.35 : 48.65), to: nil)
    let secondEdge = host.convert(NSPoint(x: 24, y: host.isFlipped ? 48.65 : 47.35), to: nil)
    func pixel(at point: NSPoint) -> Double {
      guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return -1 }
      host.cacheDisplay(in: host.bounds, to: bitmap)
      let local = host.convert(point, from: nil)
      let x = Int(4 * CGFloat(bitmap.pixelsWide) / host.bounds.width)
      let y = Int((host.isFlipped ? local.y : host.bounds.height - local.y) * CGFloat(bitmap.pixelsHigh) / host.bounds.height)
      guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return -1 }
      return color.redComponent + color.greenComponent + color.blueComponent
    }
    var failures: [String] = []
    var previousAreas: [NSTrackingArea] = []
    let normalPixels = [pixel(at: first), pixel(at: second)]
    for (index, point) in [first, second, first, second, firstEdge, secondEdge].enumerated() {
      let current = areas(at: point)
      for area in previousAreas where !current.contains(where: { $0 === area }) {
        (area.owner as? NSResponder)?.mouseExited(with:
          HoverTestEvent(area: area, type: .mouseExited, location: point))
      }
      for area in current {
        if !previousAreas.contains(where: { $0 === area }) {
          (area.owner as? NSResponder)?.mouseEntered(with: HoverTestEvent(area: area, type: .mouseEntered, location: point))
        } else {
          (area.owner as? NSResponder)?.mouseMoved(with: HoverTestEvent(area: area, type: .mouseMoved, location: point))
        }
      }
      previousAreas = current
      let expected = index.isMultiple(of: 2) ? "Accounts" : "Settings"
      var frames: [Double] = []
      var crossingFrames: [[Double]] = []
      let frameCount = index < 4 ? 2 : 64
      for frame in 0..<frameCount {
        try? await Task.sleep(for: .milliseconds(16))
        // Relayout and refresh areas as AppKit does while the highlight is changing.
        let refreshed = areas(at: point)
        for area in refreshed {
          (area.owner as? NSResponder)?.mouseMoved(with: HoverTestEvent(area: area, type: .mouseMoved, location: point))
        }
        if hover.target != expected { failures.append("Moving between controls loses the \(expected) hover target") }
        frames.append(pixel(at: point))
        crossingFrames.append([pixel(at: first), pixel(at: second)])
        if frame == 4 {
          // Same view, as during an observed model refresh while the pointer stays inside.
          host.rootView = root
        }
      }
      if index >= 4 {
        for slot in 0..<2 {
          let samples = crossingFrames.map { $0[slot] }
          let settled = samples.last!
          let minimum = min(normalPixels[slot], settled, crossingFrames[0][slot])
          let maximum = max(normalPixels[slot], settled, crossingFrames[0][slot])
          if samples.contains(where: { $0 < minimum - 0.01 || $0 > maximum + 0.01 }) {
            failures.append("Crossing controls flashes \(slot == 0 ? "Accounts" : "Settings") beyond its fade endpoints")
          }
        }
        FileHandle.standardError.write(Data("HOVER_CROSS \(expected) opacity=\(surfaceOpacity) first=\(crossingFrames.prefix(12))\n".utf8))
      }
      if frames.contains(where: { $0 < 0 }) { failures.append("\(expected) hover pixels could not be captured") }
      if frameCount > 8, let settled = frames.last, frames.suffix(48).contains(where: { abs($0 - settled) > 0.01 }) {
        failures.append("\(expected) highlight flashes after a same-view refresh")
      }
      FileHandle.standardError.write(Data("HOVER_TRANSITION \(expected) opacity=\(surfaceOpacity) frames=\(frames.count) settled=\(frames.last ?? -1)\n".utf8))
    }
    return failures
  }

  private static func hoverFeedbackFailures(name: String, control: AnyView, enabled: Bool) async -> [String] {
    let dark = NSApp.windows.first?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let host = NSHostingView(rootView: control.frame(width: 140, height: 48)
      .background(AIMTheme.canvas).environment(\.colorScheme, dark ? .dark : .light)
      .environment(\.aimDarkMode, dark))
    host.frame = NSRect(x: 0, y: 0, width: 140, height: 48)
    let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    try? await Task.sleep(for: .milliseconds(100))
    let areas = views(in: host).flatMap { view in
      view.updateTrackingAreas()
      return view.trackingAreas
    }
    let initialBounds = host.bounds
    func color() -> Double {
      host.layoutSubtreeIfNeeded()
      guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return -1 }
      host.cacheDisplay(in: host.bounds, to: bitmap)
      var total = 0.0
      var count = 0
      for y in stride(from: 0, to: bitmap.pixelsHigh, by: 5) {
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 5) {
          if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
            total += color.redComponent + color.greenComponent + color.blueComponent
            count += 1
          }
        }
      }
      return total / Double(max(count, 1))
    }
    var samples = [color()]
    var movementFlashes = false
    for type in [NSEvent.EventType.mouseEntered, .mouseExited] {
      for area in areas {
        guard let owner = area.owner as? NSResponder else { continue }
        let event = HoverTestEvent(area: area, type: type)
        if type == .mouseEntered { owner.mouseEntered(with: event) }
        else { owner.mouseExited(with: event) }
      }
      for delay in [16, 24, 120] {
        try? await Task.sleep(for: .milliseconds(delay))
        samples.append(color())
      }
      if type == .mouseEntered {
        let settled = samples.last!
        // Exercise the actual tracking host without moving the user's pointer.
        for _ in 0..<3 {
          for area in areas {
            (area.owner as? NSResponder)?.mouseMoved(with: HoverTestEvent(area: area, type: .mouseMoved))
          }
          try? await Task.sleep(for: .milliseconds(16))
          if abs(color() - settled) > 0.003 { movementFlashes = true }
        }
      }
    }
    FileHandle.standardError.write(Data("HOVER_FADE \(name) samples=\(samples)\n".utf8))
    if host.bounds != initialBounds { return ["\(name) hover changes its hitbox geometry"] }
    if movementFlashes { return ["\(name) pointer movement flashes its settled highlight"] }
    if !enabled {
      return samples.allSatisfy { abs($0 - samples[0]) < 0.003 }
        ? [] : ["\(name) highlights while disabled"]
    }
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    let minimum = min(samples[0], samples[3], samples[6])
    let maximum = max(samples[0], samples[3], samples[6])
    if samples.contains(where: { $0 < minimum - 0.01 || $0 > maximum + 0.01 }) {
      return ["\(name) flashes past its normal and hovered colors during the fade"]
    }
    return abs(samples[0] - samples[3]) > 0.02
      && abs(samples[0] - samples[6]) < 0.003
      && (reduceMotion || (
        (samples[1] != samples[3] || samples[2] != samples[3])
          && (samples[4] != samples[6] || samples[5] != samples[6])))
      ? [] : ["\(name) hover does not visibly fade in and out"]
  }

  static func presentationContractFailures() -> [String] {
    var failures: [String] = []
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
      if !condition() { failures.append(message) }
    }

    expect(AIMTheme.Dark.rail == 0x141517, "Dark rail color changed")
    expect(AIMMotion.hoverAnimation(reduceMotion: true) == nil
      && AIMMotion.hoverAnimation(reduceMotion: false) != nil,
      "Shared hover animation ignores Reduce Motion")
    expect(AIMTranslucency.opacity(25, reduceTransparency: false) == 0.75,
      "Initial content opacity is not 75 percent")
    expect(AIMTranslucency.opacity(100, reduceTransparency: false) == 0.5
      && AIMTranslucency.opacity(-1, reduceTransparency: false) == 1
      && AIMTranslucency.opacity(25, reduceTransparency: true) == 1,
      "Translucency ignores its bounds or Reduce Transparency")
    expect(AIMTheme.Dark.canvas == 0x18191B, "Dark canvas color changed")
    var lightEnvironment = EnvironmentValues()
    lightEnvironment.colorScheme = .light
    lightEnvironment.aimSurfaceOpacity = 0.5
    let primaryInk = AIMTheme.primaryInk.resolve(in: lightEnvironment)
    expect(primaryInk.opacity == 1 && primaryInk.red == 1 && primaryInk.green == 1
      && primaryInk.blue == 1, "Light primary button text inherits body translucency")
    expect(AIMTheme.Dark.panel == 0x202124, "Dark panel color changed")
    expect(AIMTheme.Dark.raised == 0x27282B, "Dark raised color changed")
    expect(AIMTheme.Dark.raisedSecondary == 0x2F3034, "Dark secondary raised color changed")
    expect(AIMTheme.Dark.hover == 0x303238, "Dark hover color changed")
    expect(AIMTheme.Dark.selection == 0x393C43, "Dark selection color changed")
    expect(AIMTheme.Dark.menuChrome == 0x18191B, "Dark menu chrome color changed")

    let hover = AIMSidebarHover()
    hover.update("first-account", inside: true)
    hover.update("second-account", inside: true)
    hover.update("first-account", inside: false)
    expect(hover.target == "second-account", "A late hover exit clears the current account highlight")
    hover.update("Accounts", inside: true)
    hover.update("second-account", inside: false)
    expect(hover.target == "Accounts", "Crossing sidebar columns leaves a stale hover target")
    hover.update("Accounts", inside: false)
    expect(hover.target == nil, "Leaving the sidebar retains its hover highlight")

    expect(UsagePresentation.credits(nil) == nil, "Missing credits are visible")
    expect(
      UsagePresentation.credits(CodexCreditsSnapshot(
        hasCredits: nil, unlimited: nil, balance: "  ")) == nil,
      "Empty credits are visible")
    expect(
      UsagePresentation.credits(CodexCreditsSnapshot(
        hasCredits: false, unlimited: nil, balance: nil)) == "None",
      "Explicit false credits are hidden")
    expect(UsagePresentation.spendControl(nil) == nil, "Missing spend control is visible")
    expect(UsagePresentation.spendControl(false) == "Not reached", "Explicit false spend control is hidden")
    let missingAccountFields = CodexAccountUsageSnapshot(
      account: nil, requiresOpenAIAuthentication: nil, rateLimits: nil, usage: nil,
      dailyUsage: [], fetchedAt: Date(timeIntervalSince1970: 0))
    expect(
      UsagePresentation.accountFacts(missingAccountFields).isEmpty,
      "Missing account facts are visible")
    expect(UsagePresentation.summaryFacts(nil).isEmpty, "Missing usage summary is visible")
    let falseAccountFields = CodexAccountUsageSnapshot(
      account: nil, requiresOpenAIAuthentication: false,
      rateLimits: CodexRateLimitsSnapshot(
        accountID: nil, ordinaryUsageAllowed: false, defaultBucket: nil, buckets: [:]),
      usage: nil, dailyUsage: [], fetchedAt: Date(timeIntervalSince1970: 0))
    expect(
      UsagePresentation.accountFacts(falseAccountFields) == [
        UsagePresentation.Fact(label: "Ordinary usage", value: "Restricted"),
        UsagePresentation.Fact(label: "Authentication", value: "Not required"),
      ],
      "Explicit false account facts are hidden")

    let emptyBucket = CodexRateLimitBucketSnapshot(
      id: "empty", name: "Empty", plan: "Plus", model: nil,
      primary: nil, secondary: nil, credits: nil, spendControlReached: nil)
    expect(!UsagePresentation.hasContent(emptyBucket), "A bucket with no metrics is visible")
    let zeroWindow = CodexRateLimitWindowSnapshot(
      usedPercent: 0, windowDurationMinutes: nil, resetsAt: nil)
    expect(UsagePresentation.hasWindow(zeroWindow), "A zero-percent quota window is hidden")
    let zeroBucket = CodexRateLimitBucketSnapshot(
      id: "zero", name: "Zero", plan: nil, model: nil,
      primary: zeroWindow, secondary: nil, credits: nil, spendControlReached: false)
    expect(UsagePresentation.hasContent(zeroBucket), "A bucket with explicit zero values is hidden")
    let creditsOnly = CodexRateLimitBucketSnapshot(
      id: "credits", name: nil, plan: nil, model: nil, primary: nil, secondary: nil,
      credits: CodexCreditsSnapshot(hasCredits: true, unlimited: nil, balance: "1"),
      spendControlReached: nil)
    expect(UsagePresentation.hasContent(creditsOnly) && !UsagePresentation.hasRateLimits(creditsOnly),
      "Credits-only data hides the missing-rate-limits notice")
    expect(UsagePresentation.emptyUsageTitle(failure: "Timed out", needsSignIn: false)
      == "Usage could not be refreshed", "An initial usage failure is shown as never checked")
    expect(UsagePresentation.emptyUsageTitle(failure: nil, needsSignIn: true)
      == "Sign in to refresh usage", "Missing sign-in state is shown as never checked")

    let zeroSummary = CodexUsageSummarySnapshot(
      lifetimeTokens: 0, peakDailyTokens: nil, currentStreakDays: 0,
      longestStreakDays: nil, longestRunningTurnSeconds: nil)
    expect(
      UsagePresentation.summaryFacts(zeroSummary).map(\.label) == ["Lifetime", "Current streak"],
      "Usage summary does not preserve explicit zero values")
    let activityEnd = ISO8601DateFormatter().date(from: "2026-09-15T12:00:00Z")!
    let activityDays = UsagePresentation.activityDays([
      CodexDailyUsageSnapshot(startDate: nil, tokens: 12),
      CodexDailyUsageSnapshot(startDate: "  ", tokens: 12),
      CodexDailyUsageSnapshot(startDate: "2026-09-14", tokens: nil),
      CodexDailyUsageSnapshot(startDate: "2026-09-14", tokens: 5),
      CodexDailyUsageSnapshot(startDate: "2026-09-14", tokens: 3),
      CodexDailyUsageSnapshot(startDate: "2026-09-15", tokens: 0),
      CodexDailyUsageSnapshot(startDate: "2026-09-08", tokens: 99),
      CodexDailyUsageSnapshot(startDate: "2026-02-30", tokens: 99),
    ], endingAt: activityEnd, dayCount: 7)
    expect(
      activityDays.map(\.tokens) == [0, 0, 0, 0, 0, 8, 0],
      "Activity calendar does not fill, filter, or aggregate daily usage")
    expect(CodexTokenPeriod.allCases.map(\.label) == [
      "Today", "Yesterday", "Weekly", "Monthly", "Yearly",
    ], "Token statistics filters changed")
    expect(CodexTokenPeriod.allCases.map(\.dayCount) == [1, 1, 7, 30, 365],
      "Token activity periods no longer drive matching calendar ranges")
    expect(UsagePresentation.formatCurrency(1_648) == "$1.6K",
      "API-equivalent currency is not compact enough for the menu bar")
    let weeks = UsagePresentation.activityWeeks(for: activityDays)
    let heatmap = ActivityHeatmap(weeks: weeks, maximumTokens: 8,
      selectedDate: nil, size: 9, select: { _ in })
    // September 14, 2026 is Monday, the second row in a Sunday-first grid.
    expect(heatmap.day(at: CGPoint(x: 31, y: 16))?.tokens == 8,
      "Heatmap hit testing or weekday labels do not select Monday's token count")
    expect(heatmap.day(at: CGPoint(x: 13, y: 16)) == nil
      && heatmap.day(at: CGPoint(x: 24.5, y: 16)) == nil
      && heatmap.day(at: CGPoint(x: 31, y: 21.5)) == nil
      && heatmap.day(at: CGPoint(x: 31, y: -1)) == nil,
      "Heatmap gutters and labels select a neighboring day")
    for (column, week) in weeks.enumerated() {
      for (row, day) in week.enumerated() {
        expect(heatmap.day(at: CGPoint(x: 19 + column * 12, y: 4 + row * 12)) == day,
          "Heatmap marker does not select its exact activity day")
      }
    }
    let mondayHeatmap = ActivityHeatmap(weeks: weeks, maximumTokens: 8,
      selectedDate: activityDays[5].date, size: 9, select: { _ in })
    expect(mondayHeatmap.selection(after: .leftArrow) == activityDays[0].date
      && mondayHeatmap.selection(after: .rightArrow) == activityDays[6].date
      && mondayHeatmap.selection(after: .upArrow) == activityDays[4].date
      && mondayHeatmap.selection(after: .downArrow) == activityDays[6].date
      && mondayHeatmap.selection(after: "a") == nil,
      "Heatmap keyboard selection skips a day or escapes the filtered date range")

    expect(HistoryHeaderLayout.height == 40, "Conversation header height changed")
    expect(HistoryHeaderLayout.countWidth >= 120, "Conversation count slot clips its label")
    expect(HistoryHeaderLayout.warningWidth == 32, "Conversation warning slot width changed")
    let codeHost = NSHostingView(rootView: ChatCodeBlock(
      language: "swift", preview: String(repeating: "longCodeLine", count: 40),
      expandedText: nil, sourceWasTruncated: false).frame(width: 300))
    codeHost.frame = NSRect(x: 0, y: 0, width: 300, height: 120)
    codeHost.layoutSubtreeIfNeeded()
    expect(!views(in: codeHost).contains(where: { $0 is NSScrollView }),
      "Code blocks capture vertical scrolling instead of letting the chat reader scroll")
    let pagingScroll = AIMOwnedScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 160))
    pagingScroll.documentView = PaginationTestDocument(frame: NSRect(x: 0, y: 0, width: 300, height: 1_000))
    var endCalls = 0
    pagingScroll.onReachEnd = { endCalls += 1 }
    pagingScroll.contentView.scroll(to: .zero)
    pagingScroll.reflectScrolledClipView(pagingScroll.contentView)
    expect(endCalls == 0, "Conversation pagination loads before the reader reaches the end")
    pagingScroll.contentView.scroll(to: NSPoint(x: 0, y: 840))
    pagingScroll.reflectScrolledClipView(pagingScroll.contentView)
    expect(endCalls > 0, "Native scrolling does not request the next message page")
    let cleanupNow = Date(timeIntervalSince1970: 1_800_000_000)
    expect(CleanupDateRange.hour.moved(.up) == .hour && CleanupDateRange.all.moved(.down) == .custom
      && CleanupDateRange.custom.moved(.down) == .custom && CleanupDateRange.custom.moved(.up) == .all
      && CleanupDateRange.all.moved(.left) == nil,
      "Cleanup range keyboard navigation escapes its options or handles unrelated arrows")
    let cutoff = cleanupNow.addingTimeInterval(-7 * 86_400)
    expect(CleanupDateRange.week.contains(cutoff, now: cleanupNow, from: cutoff, through: cleanupNow)
      && !CleanupDateRange.olderWeek.contains(cutoff, now: cleanupNow, from: cutoff, through: cleanupNow)
      && CleanupDateRange.olderWeek.contains(cutoff.addingTimeInterval(-1), now: cleanupNow, from: cutoff, through: cleanupNow),
      "Cleanup date ranges overlap or miss their boundary")
    let dayStart = Calendar.current.startOfDay(for: cleanupNow)
    let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: dayStart)!
    expect(CleanupDateRange.custom.contains(dayStart, now: cleanupNow, from: dayStart, through: dayStart)
      && !CleanupDateRange.custom.contains(nextDay, now: cleanupNow, from: dayStart, through: dayStart),
      "Cleanup custom dates exclude the first day or include the next day")
    let weeklyOnly = MenuBarUsageSnapshot(usedPercentage: nil, secondaryUsedPercentage: 1)
    expect(
      weeklyOnly.usedPercentage == nil && weeklyOnly.secondaryUsedPercentage == 1
        && (weeklyOnly.usedPercentage ?? weeklyOnly.secondaryUsedPercentage) == 1,
      "Weekly-only usage is discarded or missing from the status item")
    let weeklyPrimary = MenuBarUsageSnapshot(bucket: .init(
      id: nil, name: nil, plan: nil, model: nil,
      primary: .init(usedPercent: 1, windowDurationMinutes: 10_080, resetsAt: nil),
      secondary: nil, credits: nil, spendControlReached: nil), fetchedAt: activityEnd)
    expect(weeklyPrimary?.usedPercentage == nil && weeklyPrimary?.secondaryUsedPercentage == 1,
      "A weekly-only primary response is incorrectly labelled as five-hour usage")
    let resetNow = Date(timeIntervalSince1970: 0)
    expect(UsageResetLabel.text(until: resetNow.addingTimeInterval(2 * 86_400 - 60), now: resetNow)
      == "Resets in 1 day 23h 59m", "Reset countdown rounds almost two days up")
    expect(UsageResetLabel.text(until: resetNow.addingTimeInterval(2 * 86_400), now: resetNow)
      == "Resets in 2 days 0h 0m", "Reset countdown drops exact days")
    expect(UsageResetLabel.text(until: resetNow.addingTimeInterval(86_400 + 2 * 3_600 + 3 * 60), now: resetNow)
      == "Resets in 1 day 2h 3m", "Reset countdown drops hours or minutes")
    expect(UsageResetLabel.text(until: resetNow.addingTimeInterval(3_600), now: resetNow)
      == "Resets in 1h 0m", "Reset countdown has the wrong hour boundary")
    expect(UsageResetLabel.text(until: resetNow.addingTimeInterval(59), now: resetNow)
      == "Resets in <1m", "Reset countdown says zero minutes before reset")
    expect(UsageResetLabel.text(until: resetNow, now: resetNow) == "Resets now",
      "Reset countdown keeps counting after reset")
    failures.append(contentsOf: activityCalendarRenderFailures())
    failures.append(contentsOf: menuBarUsagePreferenceFailures())
    return failures
  }

  static func activityCalendarRenderFailures() -> [String] {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    let rows = UsagePresentation.activityDays([], endingAt: Date(), dayCount: 365)
      .enumerated().map { offset, day in
        CodexDailyUsageSnapshot(startDate: formatter.string(from: day.date), tokens: Int64(offset + 1))
      }
    let model = AccountViewModel(scenario: .demo)
    var elapsed: [Double] = []
    for _ in 0..<2 {
      let start = CFAbsoluteTimeGetCurrent()
      let host = NSHostingView(rootView: UsageActivityCalendar(rows: rows, model: model))
      host.frame = NSRect(x: 0, y: 0, width: 800, height: 160)
      host.layoutSubtreeIfNeeded()
      if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
        host.cacheDisplay(in: host.bounds, to: bitmap)
      }
      elapsed.append(CFAbsoluteTimeGetCurrent() - start)
    }
    let warm = elapsed[1]
    FileHandle.standardError.write(Data("ACTIVITY_RENDER_MS \(Int(warm * 1000))\n".utf8))
    var failures = warm < 0.2 ? [] : ["A warm yearly activity render blocks the main thread for \(Int(warm * 1000)) ms"]
    let pane = NSHostingView(rootView: AccountWindow(model: model))
    pane.frame = NSRect(x: 0, y: 0, width: 1120, height: 740)
    let window = NSWindow(contentRect: pane.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = pane
    pane.layoutSubtreeIfNeeded()
    for account in (model.status?.accounts ?? []).reversed() {
      let start = CFAbsoluteTimeGetCurrent()
      model.selectedAccountID = account.id
      pane.layoutSubtreeIfNeeded()
      if let bitmap = pane.bitmapImageRepForCachingDisplay(in: pane.bounds) {
        pane.cacheDisplay(in: pane.bounds, to: bitmap)
      }
      let milliseconds = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
      FileHandle.standardError.write(Data("ACCOUNT_SELECTION_RENDER_MS \(milliseconds)\n".utf8))
      if milliseconds >= 100 { failures.append("Ordinary account selection blocks the full pane for \(milliseconds) ms") }
    }
    return failures
  }

  static func menuBarUsagePreferenceFailures() -> [String] {
    let domain = "Switch.MenuBarUsagePreferences.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: domain) else {
      return ["Menu-bar usage preference test store is unavailable"]
    }
    defer { defaults.removePersistentDomain(forName: domain) }
    defaults.removePersistentDomain(forName: domain)

    var failures: [String] = []
    let first = UUID()
    let second = UUID()
    if MenuBarTokenPeriod.selected(defaults: defaults) != .sinceReset {
      failures.append("Menu-bar token period does not default to since reset")
    }
    defaults.set(MenuBarTokenPeriod.monthly.rawValue, forKey: MenuBarTokenPeriod.preferenceKey)
    if MenuBarTokenPeriod.selected(defaults: defaults) != .monthly {
      failures.append("Menu-bar token period does not persist")
    }
    let reset = ISO8601DateFormatter().date(from: "2026-09-21T00:00:00Z")!
    let now = ISO8601DateFormatter().date(from: "2026-09-15T12:00:00Z")!
    let usage = CodexAccountUsageSnapshot(
      account: nil, requiresOpenAIAuthentication: nil,
      rateLimits: CodexRateLimitsSnapshot(
        accountID: nil, ordinaryUsageAllowed: nil,
        defaultBucket: CodexRateLimitBucketSnapshot(
          id: nil, name: nil, plan: nil, model: nil, primary: nil,
          secondary: CodexRateLimitWindowSnapshot(
            usedPercent: 39, windowDurationMinutes: 10_080, resetsAt: reset),
          credits: nil, spendControlReached: nil),
        buckets: [:]),
      usage: nil, dailyUsage: [], fetchedAt: now)
    let rows = [
      CodexDailyUsageSnapshot(startDate: "2026-09-13", tokens: 100),
      CodexDailyUsageSnapshot(startDate: "2026-09-14", tokens: 40),
      CodexDailyUsageSnapshot(startDate: "2026-09-15", tokens: 60),
    ]
    if MenuBarTokenPeriod.sinceReset.tokens(in: rows, usage: usage, now: now) != 100 {
      failures.append("Since-reset token summary ignores the weekly reset boundary")
    }
    if !MenuBarUsagePreferences.showsUsage(for: first, defaults: defaults) {
      failures.append("Menu-bar usage does not default to on")
    }

    defaults.set(true, forKey: MenuBarUsagePreferences.defaultKey)
    if !MenuBarUsagePreferences.showsUsage(for: first, defaults: defaults) {
      failures.append("An account without an override does not follow the enabled default")
    }

    MenuBarUsagePreferences.setOverride(false, for: first, defaults: defaults)
    if MenuBarUsagePreferences.explicitValue(for: first, defaults: defaults) != false
      || MenuBarUsagePreferences.showsUsage(for: first, defaults: defaults)
    {
      failures.append("An explicit hidden choice is not preserved")
    }
    if !MenuBarUsagePreferences.showsUsage(for: second, defaults: defaults) {
      failures.append("One account’s override changes another account")
    }

    MenuBarUsagePreferences.useDefault(for: first, defaults: defaults)
    if MenuBarUsagePreferences.explicitValue(for: first, defaults: defaults) != nil
      || !MenuBarUsagePreferences.showsUsage(for: first, defaults: defaults)
    {
      failures.append("Use default does not restore inherited menu-bar usage")
    }

    MenuBarUsagePreferences.setOverride(true, for: second, defaults: defaults)
    defaults.set(false, forKey: MenuBarUsagePreferences.defaultKey)
    if MenuBarUsagePreferences.showsUsage(for: first, defaults: defaults)
      || !MenuBarUsagePreferences.showsUsage(for: second, defaults: defaults)
    {
      failures.append("Changing the default does not preserve explicit account choices")
    }
    if let reopened = UserDefaults(suiteName: domain),
      MenuBarUsagePreferences.explicitValue(for: second, defaults: reopened) != true
    {
      failures.append("Account usage choice does not survive reopening preferences")
    }
    if UsagePercentagePreferences.showsUsed(defaults: defaults)
      || UsagePercentagePreferences.label(forUsed: 42, showsUsed: false) != "58% left"
    {
      failures.append("Usage percentages do not default to percentage left")
    }
    defaults.set(true, forKey: UsagePercentagePreferences.showsUsedKey)
    if let reopened = UserDefaults(suiteName: domain),
      !UsagePercentagePreferences.showsUsed(defaults: reopened)
    {
      failures.append("Usage percentage meaning does not survive reopening preferences")
    }
    if UsagePercentagePreferences.label(forUsed: 42, showsUsed: true) != "42% used"
      || UsagePercentagePreferences.displayedPercentage(forUsed: -1, showsUsed: true) != 0
      || UsagePercentagePreferences.displayedPercentage(forUsed: 101, showsUsed: false) != 0
    {
      failures.append("Usage percentage display does not convert or clamp API values")
    }
    let hiddenAccount = MenuBarAccountSnapshot(
      id: first, identity: "Synthetic account", detail: "", isVerified: true,
      isActive: false, usage: MenuBarUsageSnapshot(usedPercentage: 42), showsUsage: false)
    if hiddenAccount.usage != nil {
      failures.append("A hidden account still publishes usage")
    }
    return failures
  }

  static func accountActionFailures() -> [String] {
    var failures: [String] = []
    let dragModel = AccountViewModel(scenario: .allStates)
    if let accounts = dragModel.status?.accounts, accounts.count == 3 {
      let cases: [(CGFloat, UUID?)] = [
        (-45, nil), (-44, accounts[0].id), (-1, accounts[0].id),
        (0, accounts[1].id), (43.999, accounts[1].id),
        (44, accounts[2].id), (87.999, accounts[2].id), (88, nil),
      ]
      for (y, expected) in cases {
        if accountDropTarget(for: accounts[1].id, at: CGPoint(x: 100, y: y), model: dragModel) != expected {
          failures.append("Sidebar drag targets the wrong account at vertical boundary \(y)")
        }
      }
      for point in [CGPoint(x: -1, y: 0), CGPoint(x: 201, y: 0),
        CGPoint(x: 0, y: CGFloat.infinity), CGPoint(x: CGFloat.nan, y: 0)] {
        if accountDropTarget(for: accounts[1].id, at: point, model: dragModel) != nil {
          failures.append("Sidebar drag accepts an outside or invalid pointer position")
        }
      }
    } else { failures.append("Sidebar drag fixture lacks three ordered accounts") }
    let doubleTick = AIMIcon(name: .doubleCheck, size: 13)
    let tickBounds = AIMDoubleCheckShape().path(
      in: CGRect(x: 0, y: 0, width: doubleTick.width, height: doubleTick.size)).boundingRect
    var checks: [[CGPoint]] = []
    AIMDoubleCheckShape().path(in: CGRect(x: 0, y: 0, width: doubleTick.width, height: doubleTick.size))
      .forEach { element in
        switch element {
        case .move(to: let point): checks.append([point])
        case .line(to: let point): checks[checks.count - 1].append(point)
        default: break
        }
      }
    if checks.count != 2 || checks.contains(where: { $0.count != 3 }) {
      failures.append("The double tick has an incomplete short or long arm")
    }
    if tickBounds.width < 15 || tickBounds.height < 9 {
      failures.append("Double-check ink is too small to distinguish both ticks at button size")
    }
    if doubleTick.width != AIMIcon(name: .check, size: 13).width {
      failures.append("Changing single/double tick shifts the account action row")
    }
    if AccountActionCopy.use != "Set as Default"
      || AccountActionCopy.usingDefault != "Using as default"
    { failures.append("Default account action uses stale labels") }
    if AccountActionCopy.copyAuthPath != "Copy auth path" {
      failures.append("Account auth-path action uses stale copy")
    }
    if AccountActionCopy.useAndOpen != "Use & Open Codex"
      || AccountActionCopy.delete != "Delete account"
    {
      failures.append("Account context actions use unexpected copy")
    }
    if AIManagerBrand.providerArtwork.map(\.providerID)
      != [.codex, .claudeCode, .geminiCLI, .antigravityCLI]
    {
      failures.append("The Add Account catalog does not map every provider to local artwork")
    }
    if AIMIcon.Name.trash.symbol != "trash" {
      failures.append("The account delete control does not use the native trash symbol")
    }
    if AIMIcon.Name.cleanup.symbol != "eraser"
      || NSImage(systemSymbolName: AIMIcon.Name.cleanup.symbol, accessibilityDescription: nil) == nil
    {
      failures.append("The Cleanup rail does not use the native eraser symbol")
    }
    if NSImage(systemSymbolName: AIMIcon.Name.menuBar.symbol, accessibilityDescription: nil) == nil {
      failures.append("The account menu-usage control has no native icon")
    }
    if [ProviderID.codex, .claudeCode, .geminiCLI, .antigravityCLI].map(\.displayName)
      != ["Codex CLI", "Claude Code", "Gemini CLI", "Antigravity CLI"]
      || ProviderID(rawValue: "grok-build").displayName != "Grok Build"
    {
      failures.append("Provider names are not derived consistently")
    }
    return failures
  }

  static func menuBarRefreshFailures() async -> [String] {
    var calls = 0
    var wasBusy = false
    var store: MenuBarPopoverStore!
    store = MenuBarPopoverStore(snapshot: MenuBarPopoverPreviewData.snapshot,
      actions: MenuBarPopoverActions(openMainWindow: {}, switchAccount: { _ in },
        refreshUsage: {
          calls += 1
          wasBusy = store.isRefreshingUsage && !store.canRefreshUsage
          await store.refreshUsage()
        }))
    await store.refreshUsage()
    var failures: [String] = []
    if calls != 1 || !wasBusy || store.isRefreshingUsage || !store.canRefreshUsage {
      failures.append("Menubar refresh does not guard duplicate requests or reset its busy state")
    }
    store.update(snapshot: MenuBarSnapshot(accounts: [MenuBarAccountSnapshot(
      id: UUID(), identity: "hidden@example.test", detail: "", isVerified: true,
      isActive: false, showsUsage: false)]))
    await store.refreshUsage()
    store.update(snapshot: MenuBarSnapshot(accounts: [MenuBarAccountSnapshot(
      id: UUID(), identity: "unsupported@example.test", detail: "", isVerified: true,
      isActive: false, providerID: .claudeCode)]))
    await store.refreshUsage()
    if calls != 1 || store.canRefreshUsage {
      failures.append("Menubar refresh runs for hidden or unsupported accounts")
    }
    return failures
  }

  @MainActor static func menuBarPopoverFailures() -> [String] {
    var failures: [String] = []
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
      if !condition() { failures.append(message) }
    }

    let defaultsDomain = "Switch.MenuBarPercentage.\(UUID().uuidString)"
    guard let controllerDefaults = UserDefaults(suiteName: defaultsDomain) else {
      return ["Menu-bar percentage test store is unavailable"]
    }
    defer { controllerDefaults.removePersistentDomain(forName: defaultsDomain) }
    controllerDefaults.removePersistentDomain(forName: defaultsDomain)

    expect(MenuBarPopover.width == 344, "Menu-bar popover is not 344 points wide")
    expect(MenuBarPopover.minimumHeight == 104, "Menu-bar popover retains removed chrome space")
    expect(MenuBarPopover.accountHeaderHeight == 35, "Menu-bar account header does not match Soft rectangles")
    expect(MenuBarPopover.quotaRowHeight == 40, "Menu-bar quota rows do not match the approved design")
    expect(MenuBarPopover.footerHeight == 29, "Menu-bar footer does not match the approved design")
    expect(MenuBarPopover.popupRadius == 9 && MenuBarPopover.cardRadius == 7
      && MenuBarPopover.buttonRadius == 3, "Menu-bar corner radii are not 9/7/3")
    expect(MenuBarPopover.accountActionWidth == 56, "Menu-bar account actions have different widths")
    expect(MenuBarPopover.accountActionHeight == 22, "Menu-bar account actions are not compact")

    let snapshot = MenuBarPopoverPreviewData.snapshot
    let hiddenAccount = MenuBarAccountSnapshot(
      id: UUID(uuidString: "FEAA8B82-542D-4B4C-9079-1A6DA349CCAA")!,
      identity: "hidden@example.test", detail: "Codex CLI · Personal",
      isVerified: true, isActive: false,
      usage: MenuBarUsageSnapshot(usedPercentage: 42), showsUsage: false)
    let empty = AIManagerStatusItemController.contentSize(accounts: [], visibleScreenHeight: 900)
    let hidden = AIManagerStatusItemController.contentSize(
      accounts: [hiddenAccount], visibleScreenHeight: 900)
    let one = AIManagerStatusItemController.contentSize(
      accounts: Array(snapshot.accounts.prefix(1)), visibleScreenHeight: 900)
    let two = AIManagerStatusItemController.contentSize(
      accounts: Array(snapshot.accounts.prefix(2)), visibleScreenHeight: 900)
    let many = AIManagerStatusItemController.contentSize(
      accounts: Array(repeating: snapshot.accounts[0], count: 20), visibleScreenHeight: 900)
    let shortScreen = AIManagerStatusItemController.contentSize(
      accounts: Array(repeating: snapshot.accounts[0], count: 20), visibleScreenHeight: 480)
    let tallScreen = AIManagerStatusItemController.contentSize(
      accounts: Array(repeating: snapshot.accounts[0], count: 20), visibleScreenHeight: 2_000)
    let fractionalScreen = AIManagerStatusItemController.contentSize(
      accounts: Array(repeating: snapshot.accounts[0], count: 20), visibleScreenHeight: 601)
    for size in [empty, hidden, one, two, many, shortScreen, tallScreen, fractionalScreen] {
      expect(size.width == 344, "Menu-bar popover width changes with its contents")
      expect(size.height >= 104, "Menu-bar popover is shorter than its empty state")
    }
    expect(empty.height == 104, "Empty menu-bar popover does not use its compact minimum height")
    expect(hidden.height == 104, "Hidden usage leaves blank quota space")
    expect(one.height == 201, "One usage card has the wrong geometry")
    expect(two.height == 353, "Two usage cards have the wrong geometry")
    expect(many.height == 720, "Menu-bar cards do not scroll at 80% of the screen height")
    expect(shortScreen.height == 384, "Menu-bar popover does not honor the visible-screen inset")
    expect(tallScreen.height == 1600, "Menu-bar retains a fixed cap below 80% of a tall screen")
    expect(fractionalScreen.height == 480, "Menu-bar screen cap rounds beyond 80%")

    expect(snapshot.accounts.first?.remainingPercentage == 58, "Preview menu snapshot lacks cached remaining quota")
    expect(snapshot.accounts.count == 3, "Preview menu snapshot does not exercise account states")
    expect(snapshot.accounts.first?.isActive == true, "Preview menu snapshot lacks an active account")
    expect(snapshot.accounts.contains(where: { !$0.isVerified }), "Preview menu snapshot lacks an unavailable row")
    expect(snapshot.accounts.compactMap(\.usage).contains(where: {
      $0.resetsAt != nil && $0.fetchedAt != nil
    }), "Preview menu snapshot lacks cached reset details")

    let controller = AIManagerStatusItemController(
      snapshot: snapshot,
      defaults: controllerDefaults,
      actions: MenuBarPopoverActions(
        openMainWindow: {}, switchAccount: { _ in }))
    expect(controller.isPresent, "Menu-bar template mark is unavailable")
    expect(controller.usesPopover, "Status item still uses a static menu")
    expect(controller.popoverContentSize.width == 344, "Hosted popover changed its fixed width")
    // Exercise the controller's intrinsic sizing rather than a manually framed snapshot.
    let sizingStore = MenuBarPopoverStore(snapshot: snapshot,
      actions: MenuBarPopoverActions(openMainWindow: {}, switchAccount: { _ in }))
    let sizingHost = NSHostingController(rootView: MenuBarPopover(store: sizingStore))
    sizingHost.view.frame = NSRect(origin: .zero, size: controller.popoverContentSize)
    sizingHost.view.layoutSubtreeIfNeeded()
    expect(sizingHost.view.fittingSize.height >= controller.popoverContentSize.height,
      "Intrinsic menu host collapses below its account cards")
    let firstAccount = Array(snapshot.accounts.prefix(1))
    for (accounts, screenHeight) in [
      (firstAccount, CGFloat(900)), (Array(snapshot.accounts.prefix(2)), CGFloat(900)),
      (Array(repeating: snapshot.accounts[0], count: 20), CGFloat(900)),
      ([hiddenAccount], CGFloat(900)), (firstAccount, CGFloat(251.25)),
      (firstAccount, CGFloat(250)),
      (Array(repeating: snapshot.accounts[0], count: 20), CGFloat(1200))
    ] {
      sizingStore.update(visibleScreenHeight: screenHeight)
      sizingStore.update(snapshot: MenuBarSnapshot(accounts: accounts))
      sizingHost.view.layoutSubtreeIfNeeded()
      let expectedSize = AIManagerStatusItemController.contentSize(
        accounts: accounts, visibleScreenHeight: sizingStore.visibleScreenHeight)
      expect(abs(sizingHost.view.fittingSize.height - expectedSize.height) < 1,
        "Native menu host does not fit its updated account count and screen cap")
      let window = NSWindow(contentRect: NSRect(origin: .zero, size: expectedSize),
        styleMask: .borderless, backing: .buffered, defer: false)
      window.contentView = sizingHost.view
      sizingHost.view.frame = NSRect(origin: .zero, size: expectedSize)
      window.contentView?.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      let scrolls = views(in: sizingHost.view).compactMap { $0 as? NSScrollView }
      expect(!scrolls.isEmpty, "Popup viewport regression did not find its native scroll view")
      for scroll in scrolls {
        let documentHeight = scroll.documentView?.frame.height ?? 0
        let viewportHeight = scroll.contentView.bounds.height
        let neededHeight = documentHeight + 20 + 29
        let cap = floor(screenHeight * 0.8)
        print("POPOVER_VIEWPORT accounts=\(accounts.count) document=\(documentHeight) viewport=\(viewportHeight) popup=\(expectedSize.height) cap=\(cap)")
        if neededHeight <= cap {
          expect(viewportHeight > 0 && documentHeight <= viewportHeight + 0.5,
            "Popup scrolls before its content reaches the display cap: \(documentHeight) > \(viewportHeight)")
          expect(scroll.verticalScroller?.isHidden != false,
            "Popup scrollbar is visible even though its cards fit")
        } else {
          expect(expectedSize.height == cap && documentHeight > viewportHeight,
            "Popup does not scroll at the opening display's 80% cap")
        }
      }
    }
    expect(controller.statusTitle == "58% 82% –", "Status item does not show enabled remaining quotas")
    let disabledSnapshot = MenuBarSnapshot(accounts: [hiddenAccount])
    controller.update(snapshot: disabledSnapshot)
    expect(controller.statusTitle.isEmpty, "Disabled usage still appears beside a provider glyph")

    let enabled = (0..<6).map { index in
      MenuBarAccountSnapshot(
        id: UUID(), identity: "account-\(index)@example.test", detail: "",
        isVerified: true, isActive: index == 5,
        usage: MenuBarUsageSnapshot(usedPercentage: index * 10),
        showsUsage: index != 1, providerID: index == 2 || index == 5 ? .claudeCode : .codex)
    }
    let capped = MenuBarSnapshot(accounts: enabled)
    expect(capped.statusAccounts.map(\.id) == [enabled[0].id, enabled[3].id, enabled[4].id, enabled[2].id],
      "Tray quotas do not group the first four enabled accounts in saved order")
    expect(capped.statusAccountGroups.map { $0.map(\.id) }
      == [[enabled[0].id, enabled[3].id, enabled[4].id], [enabled[2].id]],
      "Tray repeats a service group or changes its account order")
    controller.update(snapshot: capped)
    expect(controller.statusTitle == "100% 70% 60% 80%", "Tray quota order or meaning changed")
    expect(controller.statusAccessibilityLabel.contains("Claude Code, account-2@example.test, 80% left")
      && !controller.statusAccessibilityLabel.contains("account-1@example.test")
      && !controller.statusAccessibilityLabel.contains("account-5@example.test"),
      "Actual status button does not describe only the displayed provider/left pairs")
    controllerDefaults.set(true, forKey: UsagePercentagePreferences.showsUsedKey)
    controller.update(snapshot: capped)
    expect(controller.statusTitle == "0% 30% 40% 20%",
      "Tray percentages do not switch from left to used")
    expect(controller.statusAccessibilityLabel.contains("Claude Code, account-2@example.test, 20% used"),
      "Tray accessibility does not follow the used-percentage setting")
    controllerDefaults.set(false, forKey: UsagePercentagePreferences.showsUsedKey)
    controller.update(snapshot: capped)
    expect(controller.isPresent, "Multi-provider tray image is not a native template")
    let sameService = AIManagerBrand.statusImage(groups: [[enabled[0], enabled[3]]])
    let differentServices = AIManagerBrand.statusImage(groups: [[enabled[0]], [enabled[3]]])
    expect(sameService != nil && differentServices != nil
      && differentServices!.size.width - sameService!.size.width == 21,
      "Grouped native tray still reserves a repeated service glyph")
    for used in -1...101 {
      let account = MenuBarAccountSnapshot(
        id: UUID(), identity: "boundary@example.test", detail: "", isVerified: true,
        isActive: false, usage: MenuBarUsageSnapshot(usedPercentage: used))
      expect(account.remainingPercentage == 100 - min(max(used, 0), 100),
        "Remaining quota fails at \(used) percent used")
    }
    let weekly = MenuBarAccountSnapshot(
      id: UUID(), identity: "weekly@example.test", detail: "", isVerified: true,
      isActive: true, usage: MenuBarUsageSnapshot(usedPercentage: nil, secondaryUsedPercentage: 96))
    expect(weekly.remainingPercentage == 4, "Weekly-only quota does not show four percent remaining")
    let unknown = MenuBarAccountSnapshot(
      id: UUID(), identity: "unknown@example.test", detail: "", isVerified: true, isActive: true)
    expect(unknown.remainingPercentage == nil, "Missing quota invents a remaining percentage")
    expect(AIManagerBrand.providerGlyphNames.count == 21, "Offline brand catalog lost glyphs")
    expect(AIManagerBrand.providerGlyph(for: .codex)?.isTemplate == true
      && AIManagerBrand.providerGlyph(for: .claudeCode)?.isTemplate == true,
      "Codex or Claude Code menu glyph is unavailable")
    controller.update(snapshot: snapshot)
    let originalSize = controller.popoverContentSize
    controller.updateAppearance(NSAppearance(named: .darkAqua))
    expect(
      controller.popoverContentSize == originalSize,
      "Dark appearance changed the menu-bar popover geometry")
    controller.updateAppearance(NSAppearance(named: .aqua))
    expect(
      controller.popoverContentSize == originalSize,
      "Light appearance changed the menu-bar popover geometry")

    var copiedError: String?
    let copyStore = MenuBarPopoverStore(
      snapshot: snapshot,
      actions: MenuBarPopoverActions(
        openMainWindow: {}, switchAccount: { _ in },
        copyText: { copiedError = $0 }))
    copyStore.copyError("Synthetic menu error")
    expect(copiedError == "Synthetic menu error", "Menu-bar errors do not expose a copy action")

    // Sample actual hosted panels against the owner-selected HTML palette, including
    // appearance changes in the same virtual list. A known matte bounds backdrop variance
    // without changing the owner's Reduce Transparency preference.
    let paletteView = NSHostingView(rootView: AnyView(
      MenuBarPopover(store: copyStore)
        .environment(\.colorScheme, .light)
        .background(Color(hex: 0xF0ECE2))))
    paletteView.frame = NSRect(origin: .zero, size: originalSize)
    let paletteWindow = NSWindow(
      contentRect: paletteView.frame, styleMask: .borderless, backing: .buffered, defer: false)
    paletteWindow.appearance = NSAppearance(named: .aqua)
    paletteWindow.contentView = paletteView
    func expectPixel(_ point: NSPoint, hex: UInt32, label: String) {
      paletteView.layoutSubtreeIfNeeded()
      guard let bitmap = paletteView.bitmapImageRepForCachingDisplay(in: paletteView.bounds) else {
        failures.append("\(label) could not be captured")
        return
      }
      paletteView.cacheDisplay(in: paletteView.bounds, to: bitmap)
      let x = Int(point.x * CGFloat(bitmap.pixelsWide) / paletteView.bounds.width)
      let y = Int(point.y * CGFloat(bitmap.pixelsHigh) / paletteView.bounds.height)
      // cacheDisplay labels its rendered RGB channels as calibrated RGB; converting
      // that offscreen bitmap to sRGB introduces a gamma shift absent from the PNG.
      guard let color = bitmap.colorAt(x: x, y: y) else {
        failures.append("\(label) pixel is unavailable")
        return
      }
      let expected = [Double((hex >> 16) & 255), Double((hex >> 8) & 255), Double(hex & 255)]
      let actual = [color.redComponent, color.greenComponent, color.blueComponent]
      expect(zip(actual, expected).allSatisfy { abs($0 - $1 / 255) < 0.035 },
        "\(label) does not match its approved palette: \(actual)")
    }
    let accountSampleY: CGFloat = 26
    expectPixel(NSPoint(x: 2, y: 26), hex: 0xF0ECE2, label: "Ivory shell")
    expectPixel(NSPoint(x: 16, y: accountSampleY), hex: 0xFFFDF6, label: "Ivory account panel")
    paletteWindow.appearance = NSAppearance(named: .darkAqua)
    paletteView.rootView = AnyView(
      MenuBarPopover(store: copyStore)
        .environment(\.colorScheme, .dark)
        .background(Color(hex: 0x292722)))
    expectPixel(NSPoint(x: 2, y: 26), hex: 0x292722, label: "Espresso shell")
    expectPixel(NSPoint(x: 16, y: accountSampleY), hex: 0x3B372F, label: "Espresso account panel")
    paletteWindow.appearance = NSAppearance(named: .aqua)
    paletteView.rootView = AnyView(
      MenuBarPopover(store: copyStore)
        .environment(\.colorScheme, .light)
        .background(Color(hex: 0xF0ECE2)))
    expectPixel(NSPoint(x: 16, y: accountSampleY), hex: 0xFFFDF6,
      label: "Restored Ivory account panel")

    let glassView = NSHostingView(rootView: MenuBarPopover(store: copyStore))
    glassView.frame = NSRect(origin: .zero, size: originalSize)
    glassView.layoutSubtreeIfNeeded()
    let effects = views(in: glassView).compactMap { $0 as? NSVisualEffectView }
    let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    expect(effects.count == (reduceTransparency ? 0 : 1),
      "Menu-bar backdrop is missing, repeated per account, or ignores Reduce Transparency")
    if !reduceTransparency {
      expect(effects.first?.material == .popover && effects.first?.blendingMode == .behindWindow,
        "Menu-bar backdrop does not use native behind-window popover blur")
      expect(effects.first?.frame.size == originalSize, "Menu-bar blur does not cover the whole panel")
    }
    copyStore.update(snapshot: disabledSnapshot)
    glassView.layoutSubtreeIfNeeded()
    expect(views(in: glassView).compactMap { $0 as? NSVisualEffectView }.first === effects.first,
      "Menu-bar snapshot updates recreate the backdrop")

    controller.update(snapshot: .empty)
    expect(controller.statusTitle.isEmpty, "Status item is not icon-only when usage is unavailable")
    return failures
  }

  static func chatPresentationFailures() -> [String] {
    var failures: [String] = []
    let markdown = """
      # Heading

      A **bold** paragraph.

      > Quoted text

      - First
      - Second

      1. One
      2. Two

      ```swift
      let answer = 42
      ```
      """
    let message = ChatMessage(id: "markdown", role: .assistant, text: markdown, timestamp: nil)
    do {
      let presentation = try ChatMessagePresenter.parse(message)
      if !presentation.blocks.contains(where: { if case .heading = $0 { true } else { false } }) {
        failures.append("Chat presentation did not preserve a Markdown heading")
      }
      if !presentation.blocks.contains(where: { if case .quote = $0 { true } else { false } }) {
        failures.append("Chat presentation did not preserve a Markdown quote")
      }
      if !presentation.blocks.contains(where: { if case .unorderedList = $0 { true } else { false } }) {
        failures.append("Chat presentation did not preserve an unordered list")
      }
      if !presentation.blocks.contains(where: { if case .orderedList = $0 { true } else { false } }) {
        failures.append("Chat presentation did not preserve an ordered list")
      }
      if !presentation.blocks.contains(where: {
        if case let .code(_, language, text, _, _) = $0 {
          return language == "swift" && text == "let answer = 42"
        }
        return false
      }) {
        failures.append("Chat presentation did not preserve a fenced Swift code block")
      }
    } catch {
      failures.append("Chat presentation could not parse structured Markdown: \(error)")
    }

    let longCode = (0..<30).map { "line \($0)" }.joined(separator: "\n")
    let bounded = ChatMessage(
      id: "bounded", role: .assistant,
      text: "```text\n\(longCode)\n```\n"
        + String(repeating: "x", count: ChatMessagePresenter.maximumSourceCharacters + 1),
      timestamp: nil)
    do {
      let presentation = try ChatMessagePresenter.parse(bounded)
      if !presentation.sourceWasTruncated {
        failures.append("Chat presentation did not report its source bound")
      }
      if !presentation.blocks.contains(where: {
        if case let .code(_, _, preview, expanded, _) = $0 {
          return preview.split(separator: "\n").count == ChatMessagePresenter.compactCodeLines
            && expanded != nil
        }
        return false
      }) {
        failures.append("Chat presentation did not compact long code")
      }
    } catch {
      failures.append("Chat presentation could not apply its content bounds: \(error)")
    }

    let suiteName = "Switch.ChatFilterContract.\(UUID().uuidString)"
    if let defaults = UserDefaults(suiteName: suiteName) {
      defer { defaults.removePersistentDomain(forName: suiteName) }
      let selected: ChatMessageFilter = [.prompts, .tools]
      ChatFilterPersistence.save(selected, to: defaults)
      if ChatFilterPersistence.load(from: defaults) != selected {
        failures.append("Chat message filters do not persist their multi-selection")
      }
      defaults.set(Int.max, forKey: ChatFilterPersistence.defaultsKey)
      if ChatFilterPersistence.load(from: defaults) != .all {
        failures.append("Chat message filters do not discard unsupported saved bits")
      }
    } else {
      failures.append("Chat message filter persistence test store is unavailable")
    }

    let roles: [ChatMessageRole] = [.user, .assistant, .tool, .other]
    if roles.map(\.displayName) != ["Prompt", "Response", "Tool", "Other"] {
      failures.append("Chat message category labels are unstable")
    }
    return failures
  }

  @MainActor static func menuFailures(in mainMenu: NSMenu?, applicationName: String) -> [String] {
    guard let mainMenu else { return ["Main menu is unavailable"] }
    var failures: [String] = []
    let expectedPages = ["Accounts", "Backup", "Chat History", "Cleanup", "Settings"]
    if AIManagerPage.allCases.map(\.rawValue) != expectedPages {
      failures.append("The rail and View menu page order is incorrect")
    }
    if AIMIcon.Name.history.symbol != "bubble.left.and.bubble.right"
      || NSImage(systemSymbolName: AIMIcon.Name.history.symbol, accessibilityDescription: nil) == nil
    {
      failures.append("Chat History does not use the required system chat symbol")
    }
    if abs(AIMTheme.historyRailIconSize - (AIMTheme.railIconSize * 0.75)) > 0.001 {
      failures.append("The Chat History rail symbol is not 25 percent smaller")
    }
    let expectedMenus = [applicationName, "File", "Edit", "View", "Window", "Help"]
    if mainMenu.items.map(\.title) != expectedMenus {
      failures.append("Main menu order does not match the native menu contract")
    }
    func command(_ menu: String, _ title: String, key: String, modifiers: NSEvent.ModifierFlags = .command) {
      guard let item = mainMenu.item(withTitle: menu)?.submenu?.item(withTitle: title) else {
        failures.append("\(menu) > \(title) is missing")
        return
      }
      if item.keyEquivalent != key || item.keyEquivalentModifierMask != modifiers {
        failures.append("\(menu) > \(title) has the wrong key equivalent")
      }
    }
    func nativeCommand(_ menu: String, _ title: String, action: Selector) {
      guard let item = mainMenu.item(withTitle: menu)?.submenu?.item(withTitle: title) else {
        failures.append("\(menu) > \(title) is missing")
        return
      }
      if item.action != action { failures.append("\(menu) > \(title) does not use the native action") }
    }
    command(applicationName, "Settings…", key: ",")
    command(applicationName, "Quit \(applicationName)", key: "q")
    command("File", "Add Account…", key: "n")
    command("File", "Advanced Import…", key: "i", modifiers: [.command, .shift])
    command("File", "Close Window", key: "w")
    command("Window", "Minimize", key: "m")
    for (index, page) in AIManagerPage.allCases.enumerated() {
      command("View", page.rawValue, key: String(index + 1))
    }
    for (menu, title, action) in [
      (applicationName, "About \(applicationName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
      (applicationName, "Hide \(applicationName)", #selector(NSApplication.hide(_:))),
      (applicationName, "Hide Others", #selector(NSApplication.hideOtherApplications(_:))),
      (applicationName, "Show All", #selector(NSApplication.unhideAllApplications(_:))),
      (applicationName, "Quit \(applicationName)", #selector(NSApplication.terminate(_:))),
      ("Edit", "Cut", #selector(NSText.cut(_:))),
      ("Edit", "Copy", #selector(NSText.copy(_:))),
      ("Edit", "Paste", #selector(NSText.paste(_:))),
      ("Edit", "Select All", #selector(NSText.selectAll(_:))),
      ("Window", "Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
      ("Help", "\(applicationName) Help", #selector(NSApplication.showHelp(_:))),
    ] {
      nativeCommand(menu, title, action: action)
    }
    if mainMenu.item(withTitle: applicationName)?.submenu?.item(withTitle: "Services")?.submenu !== NSApp.servicesMenu {
      failures.append("The application Services menu is not registered")
    }
    if mainMenu.item(withTitle: "Window")?.submenu !== NSApp.windowsMenu {
      failures.append("The Window menu is not registered with AppKit")
    }
    if mainMenu.item(withTitle: "Help")?.submenu !== NSApp.helpMenu {
      failures.append("The Help menu is not registered with AppKit")
    }
    let windowItems = mainMenu.item(withTitle: "Window")?.submenu?.items ?? []
    if windowItems.contains(where: { $0.action == #selector(NSWindow.performZoom(_:)) || $0.title.contains("Zoom") }) {
      failures.append("The fixed window exposes a maximize command")
    }
    return failures
  }

  @MainActor static func exerciseMenuNavigation(in window: NSWindow?) -> [String] {
    guard let mainMenu = NSApp.mainMenu, let window else { return ["Menu navigation test could not resolve the app window"] }
    var failures: [String] = []
    var shownPages: [AIManagerPage] = []
    let observer = NotificationCenter.default.addObserver(
      forName: AIManagerNavigation.didShowPage, object: nil, queue: .main
    ) { notification in
      if let page = notification.object as? AIManagerPage { shownPages.append(page) }
    }
    defer { NotificationCenter.default.removeObserver(observer) }

    window.orderOut(nil)
    let settings = mainMenu.item(withTitle: mainMenu.items[0].title)?.submenu?.item(withTitle: "Settings…")
    if let settings, let action = settings.action {
      if !NSApp.sendAction(action, to: settings.target, from: settings) {
        failures.append("Command+, could not dispatch its action")
      }
    } else {
      failures.append("Command+, could not resolve its menu item")
    }
    if !window.isVisible { failures.append("Command+, did not bring the main window forward") }
    if shownPages.last != .settings { failures.append("Command+, did not navigate to Settings") }

    for page in AIManagerPage.allCases {
      guard let item = mainMenu.item(withTitle: "View")?.submenu?.item(withTitle: page.rawValue),
            let action = item.action else {
        failures.append("View > \(page.rawValue) could not resolve its action")
        continue
      }
      _ = NSApp.sendAction(action, to: item.target, from: item)
      if shownPages.last != page { failures.append("View > \(page.rawValue) did not navigate") }
    }
    return failures
  }

  // Acceptance points use the screenshot's top-left origin; AppKit content views usually do not.
  static func titleDragTarget(in window: NSWindow, at point: NSPoint) -> Bool {
    guard let contentView = window.contentView else { return false }
    return hitTest(in: contentView, atTopOriginPoint: point) is AIMTitleDragView
  }

  static func focusPolicyMatches(in root: NSView, indicatorsEnabled: Bool) -> Bool {
    root.focusRingType == (indicatorsEnabled ? .default : .none)
  }

  static func defaultFocusIndicatorsAreHidden(in window: NSWindow) -> Bool {
    window.contentView?.focusRingType == NSFocusRingType.none
  }

  static func windowControlGeometryMatches() -> Bool {
    let size = AIMTheme.windowControlSize
    return size == 48 && AIMTheme.railWidth == size
      && AIMTheme.topbarHeight == size && AIMTheme.modalTitlebarHeight == size
      && AIMTheme.modalHeight == 648 && AIMTheme.addAccountModalHeight == 480
      && AIMTheme.modalOuterInset == 24
      && AIMTheme.modalSectionSpacing == 16
  }

  static func windowPlacementFailures() -> [String] {
    var failures: [String] = []
    let size = NSSize(width: 1120, height: 740)
    let primary = AIManagerDisplayDescriptor(
      identifier: "primary", name: "Built-in Display",
      frame: NSRect(x: 0, y: 0, width: 1728, height: 1117),
      visibleFrame: NSRect(x: 0, y: 38, width: 1728, height: 1054))
    let external = AIManagerDisplayDescriptor(
      identifier: "external", name: "External Display",
      frame: NSRect(x: -2560, y: 120, width: 2560, height: 1440),
      visibleFrame: NSRect(x: -2560, y: 120, width: 2560, height: 1416))
    let original = NSRect(x: -2200, y: 620, width: size.width, height: size.height)
    let placement = AIManagerWindowPlacement.placement(for: original, on: external)
    if AIManagerWindowPlacement.restoredFrame(
      for: placement, windowSize: size, displays: [primary, external]) != original
    {
      failures.append("Window placement does not restore a negative-coordinate display")
    }

    let rearrangedExternal = AIManagerDisplayDescriptor(
      identifier: "external", name: "External Display",
      frame: NSRect(x: 1728, y: -400, width: 2560, height: 1440),
      visibleFrame: NSRect(x: 1728, y: -400, width: 2560, height: 1416))
    let expectedRearranged = NSRect(x: 2088, y: 100, width: size.width, height: size.height)
    if AIManagerWindowPlacement.restoredFrame(
      for: placement, windowSize: size, displays: [primary, rearrangedExternal])
      != expectedRearranged
    {
      failures.append("Window placement does not follow a rearranged saved display")
    }
    if AIManagerWindowPlacement.restoredFrame(
      for: placement, windowSize: size, displays: [primary]) != nil
    {
      failures.append("Window placement falls back to the wrong display")
    }

    let legacy = "-2200 620 1120 740 -2560 120 2560 1410"
    if AIManagerWindowPlacement.legacyPlacement(
      from: legacy, displays: [primary, external]) != placement
    {
      failures.append("Legacy AppKit placement does not tolerate usable-frame changes")
    }
    let unrelatedLegacy = "7000 7000 1120 740 7000 7000 2560 1440"
    if AIManagerWindowPlacement.legacyPlacement(
      from: unrelatedLegacy, displays: [primary, external]) != nil
    {
      failures.append("Legacy AppKit placement migrates to an unrelated display")
    }

    let domain = "com.mandalsuraj.ai-manager.acceptance.window-placement"
    if let defaults = UserDefaults(suiteName: domain) {
      defaults.removePersistentDomain(forName: domain)
      AIManagerWindowPlacement.store(placement, defaults: defaults)
      if AIManagerWindowPlacement.load(defaults: defaults) != placement {
        failures.append("Window placement does not persist through UserDefaults")
      }
      defaults.removePersistentDomain(forName: domain)
    } else {
      failures.append("Window placement test defaults are unavailable")
    }

    let farOutside = AIManagerStoredWindowPlacement(
      version: 1, displayIdentifier: "external", displayName: "External Display",
      displayFrameX: external.frame.minX, displayFrameY: external.frame.minY,
      displayFrameWidth: external.frame.width, displayFrameHeight: external.frame.height,
      leftOffset: 99_999, topOffset: 99_999)
    guard let clamped = AIManagerWindowPlacement.restoredFrame(
      for: farOutside, windowSize: size, displays: [external])
    else {
      failures.append("Window placement did not produce a clamped frame")
      return failures
    }
    if !external.visibleFrame.contains(clamped) {
      failures.append("Window placement did not clamp into the display visible frame")
    }
    return failures
  }

  static func scrollBehaviorIsInstalled(in root: NSView) -> Bool {
    let scrollViews = views(in: root).compactMap { $0 as? NSScrollView }
    return !scrollViews.isEmpty && configuredScrollViewCount(in: root) == scrollViews.count
      && scrollViews.allSatisfy { scroll in
        guard let document = scroll.documentView else { return false }
        return document.frame.height > 0 && scroll.contentView.bounds.height > 0
          && abs(document.frame.width - scroll.contentView.bounds.width) < 1
          && abs(scroll.contentView.frame.width - scroll.bounds.width) < 1
      }
  }

  static func configuredScrollViewCount(in root: NSView) -> Int {
    views(in: root).compactMap { $0 as? NSScrollView }.filter {
      $0.autohidesScrollers && $0.verticalScroller is AIMThinScroller
        && ($0.scrollerStyle == .overlay
          || abs($0.contentView.frame.width - $0.bounds.width) < 1)
    }.count
  }

  static func historySearchFieldsMatch(in root: NSView) -> Bool {
    let placeholders = Set(views(in: root).compactMap {
      ($0 as? NSTextField)?.placeholderString
    })
    return placeholders.contains("Search conversations") && placeholders.contains("Search this chat")
  }

  static func virtualHistoryScrollCount(in root: NSView) -> Int {
    views(in: root).filter { $0 is AIMVirtualTableView }.count
  }

  static func realizedVirtualRowCount(in root: NSView) -> Int {
    views(in: root).filter { $0 is NSTableRowView }.count
  }

  static func scrollAppearancesMatch(in root: NSView, appearance: NSAppearance) -> Bool {
    views(in: root).compactMap { $0 as? NSScrollView }.allSatisfy {
      $0.documentView?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        == appearance.bestMatch(from: [.darkAqua, .aqua])
    }
  }

  static func scrollIdentity(in root: NSView) -> String {
    views(in: root).compactMap { $0 as? NSScrollView }
      .map { String(describing: ObjectIdentifier($0)) }.joined(separator: ",")
  }

  static func hasVisualEffect(in root: NSView) -> Bool {
    views(in: root).contains { $0 is NSVisualEffectView }
  }

  static func hierarchySnapshot(in root: NSView) -> [AIManagerNativeViewSnapshot] {
    snapshot(view: root, path: "0")
  }

  static func hitTestPath(in window: NSWindow, atTopOriginPoint point: NSPoint) -> [String] {
    guard let contentView = window.contentView else { return [] }
    var current = hitTest(in: contentView, atTopOriginPoint: point)
    var path: [String] = []
    while let view = current {
      path.append(
        "\(NSStringFromClass(type(of: view))) frame=\(NSStringFromRect(view.frame)) flipped=\(view.isFlipped)"
      )
      current = view.superview
    }
    return path
  }

  private static func views(in root: NSView) -> [NSView] {
    [root] + root.subviews.flatMap { views(in: $0) }
  }

  private static func snapshot(view: NSView, path: String) -> [AIManagerNativeViewSnapshot] {
    let scrollView = view as? NSScrollView
    let item = AIManagerNativeViewSnapshot(
      path: path,
      className: NSStringFromClass(type(of: view)),
      frameX: view.frame.minX,
      frameY: view.frame.minY,
      frameWidth: view.frame.width,
      frameHeight: view.frame.height,
      isFlipped: view.isFlipped,
      focusRingType: view.focusRingType.rawValue,
      scrollStyle: scrollView.map { $0.scrollerStyle == .overlay ? "overlay" : "legacy" },
      autohidesScrollers: scrollView?.autohidesScrollers,
      verticalScrollerClass: scrollView?.verticalScroller.map { NSStringFromClass(type(of: $0)) }
    )
    return [item]
      + view.subviews.enumerated().flatMap { index, child in
        snapshot(view: child, path: "\(path).\(index)")
      }
  }

  private static func appKitPoint(fromTopOrigin point: NSPoint, in view: NSView) -> NSPoint {
    view.isFlipped ? point : NSPoint(x: point.x, y: view.bounds.height - point.y)
  }

  private static func hitTest(in view: NSView, atTopOriginPoint point: NSPoint) -> NSView? {
    let localPoint = appKitPoint(fromTopOrigin: point, in: view)
    let pointForHitTest = view.superview.map { view.convert(localPoint, to: $0) } ?? localPoint
    return view.hitTest(pointForHitTest)
  }
}
