import AIManagerCore
import SwiftUI

// The four Overview charts, after uiarc.dev: a streamgraph, an activity heatmap, a ridgeline, and
// a waffle chart. Each is a Canvas inside an Animatable view. A 0...1 clock draws it in on first
// appear and on every period or grouping change; hovering dims the other series. The data and the
// colors come from OverviewDataset (OverviewPage.swift).

// MARK: - Motion

enum OverviewMotion {
  /// Draw-in lengths, inside the 150-600 ms budget.
  static let stream = 0.6, heatmap = 0.6, ridge = 0.6, waffle = 0.5
  static let hover = Animation.easeOut(duration: 0.12)
  static let follow = Animation.spring(duration: 0.26, bounce: 0.12)
  /// How far the other series fade while one is hovered.
  static let dimmed = 0.38

  /// Ease-out cubic for the part of the clock a shape owns.
  static func ease(_ t: Double) -> Double { 1 - pow(1 - min(max(t, 0), 1), 3) }
  static func window(_ clock: Double, start: Double, length: Double) -> Double {
    ease((clock - start) / length)
  }

  /// Preview screenshots: `--overview-hover=stream:0.5:0.4` puts the pointer at those fractions of that chart.
  static func previewHover(_ chart: String, in size: CGSize) -> CGPoint? {
    #if AI_MANAGER_PREVIEW
    let parts = (PreviewArguments.value("overview-hover") ?? "").split(separator: ":")
    guard parts.count == 3, parts[0] == chart, let x = Double(parts[1]), let y = Double(parts[2]) else { return nil }
    return CGPoint(x: x * size.width, y: y * size.height)
    #else
    return nil
    #endif
  }

  /// A frozen clock: `--overview-progress=0.3` renders a mid-animation frame; offscreen contract
  /// renders show the final state. Nil means the clock runs.
  static var fixedProgress: Double? {
    #if AI_MANAGER_PREVIEW
    if let value = PreviewArguments.value("overview-progress").flatMap(Double.init) { return value }
    #endif
    return AIMMotion.isLive ? nil : 1
  }
}

/// Runs a 0...1 clock on appear and whenever `key` changes, and hands it to the chart. A new run
/// restarts from 0, so a draw-in is interruptible. Reduce Motion skips the geometry and fades.
struct OverviewDrawIn<Content: View>: View {
  let key: Int
  let duration: Double
  let content: (Double) -> Content
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// False for content that scrolls into view: it draws at once, never from zero.
  @Environment(\.aimAnimatesAppearance) private var animatesAppearance
  @State private var runs = 0

  var body: some View {
    if let fixed = OverviewMotion.fixedProgress {
      content(fixed)
    } else if !animatesAppearance {
      content(1)
    } else {
      Color.clear
        .keyframeAnimator(initialValue: 0.0, trigger: key &* 31 &+ runs) { _, clock in
          content(reduceMotion ? 1 : clock).opacity(reduceMotion ? clock : 1)
        } keyframes: { _ in
          LinearKeyframe(1.0, duration: reduceMotion ? 0.2 : duration)
        }
        // The first appearance only; a later one (scrolling back) keeps the drawn chart. A new key replays it.
        .onAppear { if runs == 0 { runs = 1 } }
    }
  }
}

// MARK: - Curves

extension Path {
  /// A monotone cubic curve through points that are sorted by x (either way). It is smooth and
  /// never dips below a flat run, so a ridge with zero days stays on its baseline.
  mutating func addMonotone(_ points: [CGPoint], connect: Bool) {
    guard let first = points.first else { return }
    if connect { addLine(to: first) } else { move(to: first) }
    let count = points.count
    guard count > 1 else { return }
    let slopes = (0..<count - 1).map { index -> CGFloat in
      let dx = points[index + 1].x - points[index].x
      return (points[index + 1].y - points[index].y) / (dx == 0 ? 0.0001 : dx)
    }
    var tangents = [CGFloat](repeating: 0, count: count)
    tangents[0] = slopes[0]
    tangents[count - 1] = slopes[count - 2]
    for index in 1..<max(count - 1, 1) {
      let (a, b) = (slopes[index - 1], slopes[index])
      tangents[index] = a * b > 0 ? 2 * a * b / (a + b) : 0
    }
    for index in 0..<count - 1 {
      let (from, to) = (points[index], points[index + 1])
      let third = (to.x - from.x) / 3
      addCurve(
        to: to,
        control1: CGPoint(x: from.x + third, y: from.y + tangents[index] * third),
        control2: CGPoint(x: to.x - third, y: to.y - tangents[index + 1] * third))
    }
  }
}

// MARK: - Hover and tooltip

struct OverviewTip: Equatable {
  struct Row: Equatable {
    var color: Color?
    /// The tool behind the series this row names; its brand tile precedes the label.
    var service: String?
    var label: String
    var value: String
  }
  var title: String
  /// The tool behind a title that names a series.
  var titleService: String?
  var rows: [Row]
}

struct OverviewHover: Equatable {
  var point: CGPoint
  var tip: OverviewTip
  /// The series under the pointer, for dimming the others.
  var key: String?
  /// The day or cell index under the pointer.
  var index: Int?
}

extension OverviewHover {
  /// Posted when a sheet opens over the Overview: the chart under it never gets a pointer-left event.
  static let endAll = Notification.Name("switch.overview.endHover")
}

extension View {
  /// Ends a chart hover when its window resigns key (a sheet becomes key) or a sheet opens over the
  /// page, so no tooltip or dimmed series stays behind a cover.
  func endsHover(_ end: @escaping () -> Void) -> some View {
    onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in end() }
      .onReceive(NotificationCenter.default.publisher(for: OverviewHover.endAll)) { _ in end() }
  }
}

/// The tooltip follows the pointer on a soft spring and flips to the pointer's other side near an edge.
struct OverviewTooltipLayer: View {
  let hover: OverviewHover?
  let size: CGSize
  var flips = true
  /// The widest a series name grows ("Claude Code · name@example.com"); longer names shorten in the middle.
  static let nameWidth: CGFloat = 280
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// The last tip. One tooltip view stays once it appears: its content changes and its opacity
  /// fades, so a fade-out never overlaps the next tip.
  @State private var last: OverviewHover?

  private var current: OverviewHover? { hover ?? last }

  var body: some View {
    Color.clear.overlay(alignment: alignment) {
      if let current {
        tip(current.tip)
          .padding(insets(for: current.point))
          .animation(reduceMotion ? nil : OverviewMotion.follow, value: current.point)
          .opacity(hover == nil ? 0 : 1)
          .transition(.opacity)
      }
    }
    .allowsHitTesting(false)
    .animation(AIMMotion.fade(AIMMotion.hover), value: hover == nil)
    .onChange(of: hover) { _, next in if let next { last = next } }
    // Drop the faded-out tip, so the next one fades in at its own place instead of sliding there.
    .task(id: hover == nil) {
      guard hover == nil else { return }
      try? await Task.sleep(for: .milliseconds(300))
      if !Task.isCancelled, hover == nil { last = nil }
    }
  }

  private var alignment: Alignment {
    guard let point = current?.point else { return .topLeading }
    return Alignment(horizontal: onRight(point) ? .leading : .trailing, vertical: below(point) ? .top : .bottom)
  }

  private func onRight(_ point: CGPoint) -> Bool { !flips || point.x < size.width * 0.6 }
  private func below(_ point: CGPoint) -> Bool { point.y < size.height * 0.55 }

  private func insets(for point: CGPoint) -> EdgeInsets {
    let right = onRight(point), under = below(point)
    // A tall tooltip (the heatmap's tool rows in a short chart) slides along the pointer's side so it
    // stays inside the chart instead of running out of the card, where the card would clip it.
    let room = max(size.height - estimatedHeight, 0)
    return EdgeInsets(
      top: under ? min(point.y + 14, room) : 0, leading: right ? point.x + 14 : 0,
      bottom: under ? 0 : min(max(size.height - point.y + 14, 0), room),
      trailing: right ? 0 : max(size.width - point.x + 14, 0))
  }

  /// About the tooltip's height: padding, a title line, and a line for each row.
  private var estimatedHeight: CGFloat { 30 + 18 * CGFloat(current?.tip.rows.count ?? 0) }

  private func tip(_ tip: OverviewTip) -> some View {
    let shape = RoundedRectangle(cornerRadius: AIMTheme.tileRadius, style: .continuous)
    return VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        OverviewServiceTile(service: tip.titleService)
        Text(tip.title).aimText(.body).lineLimit(1).truncationMode(.middle)
          .frame(maxWidth: Self.nameWidth, alignment: .leading)
      }
      ForEach(Array(tip.rows.enumerated()), id: \.offset) { _, row in
        HStack(spacing: 6) {
          if let color = row.color { Circle().fill(color).frame(width: 8, height: 8) }
          OverviewServiceTile(service: row.service)
          Text(row.label).aimText(.secondary).lineLimit(1).truncationMode(.middle)
            .frame(maxWidth: Self.nameWidth, alignment: .leading)
          Spacer(minLength: 12)
          Text(row.value).aimText(.secondary).monospacedDigit()
        }
      }
    }
    .padding(8)
    .frame(minWidth: 120, alignment: .leading)
    .fixedSize()
    .background(AIMTheme.card, in: shape)
    .aimBorder(AIMTheme.cardBorder, in: shape)
    .shadow(color: .black.opacity(0.16), radius: 6, y: 2)
  }
}

// MARK: - Legend

/// Color dots, tool tiles, and names, the same colors as the chart. It is one line high so a grouping
/// with more names never moves the card; names that do not fit all shorten together with "…" (the
/// other charts name every series).
struct OverviewLegend: View {
  static let height: CGFloat = 18
  let series: [OverviewSeries]
  /// The series a hovered ridge or band belongs to: its name brightens and the others dim.
  var active: String?

  var body: some View {
    HStack(spacing: 14) {
      ForEach(series) { item in
        HStack(spacing: 6) {
          Circle().fill(item.color).frame(width: 8, height: 8)
          OverviewServiceTile(service: item.service)
          Text(item.label).aimText(.secondary, tint: active == item.id ? Color.primary : nil).lineLimit(1)
        }
        .opacity(active == nil || active == item.id ? 1 : OverviewMotion.dimmed)
        .accessibilityHidden(true)
      }
    }
    .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height, alignment: .topLeading)
    .clipped()
    .animation(AIMMotion.fade(AIMMotion.hover), value: active)
  }
}

// MARK: - Date axis

/// A faint row of 3 to 5 date labels under a time chart: weekdays for a week, month and day for longer.
/// A label sits at its tick's x, but the first starts and the last ends `inset` inside the edges, so a
/// chart that runs edge to edge keeps its labels inside the card inset.
struct OverviewDateAxis: View {
  static let height: CGFloat = 16
  let days: [String]
  var inset: CGFloat = 0

  /// Where a label draws: its tick x, clamped so the first label starts and the last ends inside `inset`.
  static func labelX(fraction: Double, first: Bool, last: Bool, width: CGFloat, inset: CGFloat) -> CGFloat {
    let x = width * fraction
    return first ? max(x, inset) : (last ? min(x, width - inset) : x)
  }

  static func labels(_ days: [String]) -> [(fraction: Double, text: String)] {
    guard days.count > 1 else { return [] }
    let last = days.count - 1
    let picks = days.count <= 7 ? Array(stride(from: 0, through: last, by: 2)) : (0...4).map { Int((Double($0) * Double(last) / 4).rounded()) }
    return picks.map { (Double($0) / Double(last), days.count <= 7 ? OverviewDay.weekdayName(days[$0]) : OverviewDay.short(days[$0])) }
  }

  var body: some View {
    Canvas { context, size in
      let labels = Self.labels(days)
      for (index, label) in labels.enumerated() {
        let text = Text(label.text).font(AIMTextRole.caption.font).foregroundStyle(Color(nsColor: .tertiaryLabelColor))
        let (first, last) = (index == 0, index == labels.count - 1)
        let anchor: UnitPoint = first ? .topLeading : (last ? .topTrailing : .top)
        let x = Self.labelX(fraction: label.fraction, first: first, last: last, width: size.width, inset: inset)
        context.draw(text, at: CGPoint(x: x, y: 2), anchor: anchor)
      }
    }
    .frame(height: Self.height)
    .accessibilityHidden(true)
  }
}

// MARK: - Streamgraph

enum OverviewStreamLayout {
  static let inset: CGFloat = 6

  // ponytail: a centered (silhouette) baseline, not uiarc's wiggle; add wiggle if bands read as a mirrored blob.
  /// Stacked bands around a centered axis, top to bottom in series order. `swell` scales the
  /// bands about the axis, so the draw-in grows out of a hairline.
  static func layers(
    _ series: [OverviewSeries], size: CGSize, swell: Double = 1
  ) -> [(top: [CGPoint], bottom: [CGPoint])] {
    guard let count = series.first?.daily.count, count > 1 else { return [] }
    let totals = (0..<count).map { index in series.reduce(0.0) { $0 + Double($1.daily[index]) } }
    let scale = (size.height - 2 * inset) / max(totals.max() ?? 1, 1)
    let mid = size.height / 2
    var cursor = totals.map { mid - $0 * scale / 2 }
    return series.map { item in
      var top: [CGPoint] = [], bottom: [CGPoint] = []
      for index in 0..<count {
        let x = size.width * Double(index) / Double(count - 1)
        let (from, to) = (cursor[index], cursor[index] + Double(item.daily[index]) * scale)
        top.append(CGPoint(x: x, y: mid + (from - mid) * swell))
        bottom.append(CGPoint(x: x, y: mid + (to - mid) * swell))
        cursor[index] = to
      }
      return (top, bottom)
    }
  }
}

private struct OverviewStreamCanvas: View, Animatable {
  let series: [OverviewSeries]
  let clock: Double
  var engaged: Double
  let highlight: String?
  let day: Int?
  var animatableData: Double {
    get { engaged }
    set { engaged = newValue }
  }

  var body: some View {
    Canvas { context, size in
      let layers = OverviewStreamLayout.layers(series, size: size, swell: OverviewMotion.ease(clock))
      for (index, layer) in layers.enumerated() {
        var path = Path()
        path.addMonotone(layer.top, connect: false)
        path.addMonotone(layer.bottom.reversed(), connect: true)
        path.closeSubpath()
        let faded = highlight != nil && series[index].id != highlight
        let opacity = 0.82 * (faded ? 1 - engaged * (1 - OverviewMotion.dimmed) : 1)
        context.fill(path, with: .color(series[index].color.opacity(opacity)))
        context.stroke(path, with: .color(AIMTheme.card), lineWidth: 2)
      }
      if let day, let count = series.first?.daily.count, count > 1 {
        let x = size.width * Double(day) / Double(count - 1)
        var line = Path()
        line.move(to: CGPoint(x: x, y: 0))
        line.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(line, with: .color(Color.primary.opacity(0.35 * engaged)), lineWidth: 1)
      }
    }
  }
}

struct OverviewStreamChart: View {
  let dataset: OverviewDataset
  @State private var hover: OverviewHover?
  @State private var lastKey: String?

  var body: some View {
    VStack(spacing: 4) {
      // Above the axis, so a tooltip over the plot's bottom edge never draws under the labels.
      plot.zIndex(1)
      OverviewDateAxis(days: dataset.days, inset: AIMTheme.cardInset)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(dataset.streamSummary)
    .accessibilityAddTraits(.isImage)
    .endsHover { hover = nil }
  }

  private var plot: some View {
    GeometryReader { proxy in
      OverviewDrawIn(key: dataset.drawKey, duration: OverviewMotion.stream) { clock in
        OverviewStreamCanvas(
          series: dataset.series, clock: clock, engaged: hover == nil ? 0 : 1,
          highlight: hover?.key ?? lastKey, day: hover?.index)
          .animation(OverviewMotion.hover, value: hover == nil)
      }
      .contentShape(Rectangle())
      .onContinuousHover { phase in
        switch phase {
        case .active(let point):
          hover = info(at: point, size: proxy.size)
          if let key = hover?.key { lastKey = key }
        case .ended: hover = nil
        }
      }
      .overlay { OverviewTooltipLayer(hover: hover, size: proxy.size) }
      .onAppear {
        if let point = OverviewMotion.previewHover("stream", in: proxy.size) {
          hover = info(at: point, size: proxy.size)
          lastKey = hover?.key
        }
      }
    }
  }

  private func info(at point: CGPoint, size: CGSize) -> OverviewHover? {
    let count = dataset.days.count
    guard count > 1, size.width > 0 else { return nil }
    let day = min(max(Int((point.x / size.width * Double(count - 1)).rounded()), 0), count - 1)
    let layers = OverviewStreamLayout.layers(dataset.series, size: size)
    guard !layers.isEmpty else { return nil }
    // The band under the pointer, or the nearest band when the pointer is above or below them.
    let distances = layers.map { layer -> CGFloat in
      let (top, bottom) = (layer.top[day].y, layer.bottom[day].y)
      return point.y < top ? top - point.y : (point.y > bottom ? point.y - bottom : 0)
    }
    guard let index = distances.indices.min(by: { distances[$0] < distances[$1] }) else { return nil }
    let item = dataset.series[index]
    let total = dataset.series.reduce(0) { $0 + $1.daily[day] }
    let tip = OverviewTip(
      title: OverviewDay.short(dataset.days[day]),
      rows: [
        .init(color: item.color, service: item.service, label: item.tipLabel, value: UsagePresentation.formatTokens(item.daily[day])),
        .init(color: nil, label: "All", value: UsagePresentation.formatTokens(total)),
      ])
    return OverviewHover(point: point, tip: tip, key: item.id, index: day)
  }
}

// MARK: - Activity heatmap

/// 53 week columns by 7 weekday rows, Sunday first, with a month band on top and weekday names at left.
struct OverviewHeatLayout {
  static let gap: CGFloat = 3
  static let left: CGFloat = 30
  static let top: CGFloat = 18
  let size: CGSize
  let offset: Int
  let count: Int

  var columns: Int { (offset + count + 6) / 7 }
  var cell: CGSize {
    CGSize(
      width: max((size.width - Self.left - Self.gap * CGFloat(columns - 1)) / CGFloat(columns), 1),
      height: max((size.height - Self.top - Self.gap * 6) / 7, 1))
  }

  func rect(column: Int, row: Int) -> CGRect {
    let cell = cell
    return CGRect(
      x: Self.left + CGFloat(column) * (cell.width + Self.gap),
      y: Self.top + CGFloat(row) * (cell.height + Self.gap), width: cell.width, height: cell.height)
  }

  func rect(index: Int) -> CGRect { rect(column: (offset + index) / 7, row: (offset + index) % 7) }

  /// The day under a point, or nil in a gap, the margins, or the empty cells of the first or last week.
  func index(at point: CGPoint) -> Int? {
    let cell = cell
    let (x, y) = (point.x - Self.left, point.y - Self.top)
    guard x >= 0, y >= 0 else { return nil }
    let column = Int(x / (cell.width + Self.gap)), row = Int(y / (cell.height + Self.gap))
    guard column < columns, row < 7,
          x - CGFloat(column) * (cell.width + Self.gap) <= cell.width,
          y - CGFloat(row) * (cell.height + Self.gap) <= cell.height else { return nil }
    let index = column * 7 + row - offset
    return (0..<count).contains(index) ? index : nil
  }
}

private struct OverviewHeatCanvas: View, Animatable {
  let dataset: OverviewDataset
  let clock: Double
  var engaged: Double
  let cell: Int?
  let level: Int?
  var animatableData: Double {
    get { engaged }
    set { engaged = newValue }
  }

  var body: some View {
    Canvas { context, size in
      // Read once: yearOffset parses a date string on every access.
      let offset = dataset.yearOffset
      let layout = OverviewHeatLayout(size: size, offset: offset, count: dataset.yearDays.count)
      let columns = Double(layout.columns + 6)
      for index in dataset.yearDays.indices {
        let rect = layout.rect(index: index)
        // A diagonal wave: the top-left cells land first.
        let slot = (offset + index) / 7 + (offset + index) % 7
        let arrive = OverviewMotion.window(clock, start: Double(slot) / columns * 0.62, length: 0.38)
        let scale = 0.5 + 0.5 * arrive
        let shape = rect.insetBy(dx: rect.width * (1 - scale) / 2, dy: rect.height * (1 - scale) / 2)
        let value = dataset.heatLevel(dataset.yearTotals[index])
        var opacity = arrive
        if let level, level != value { opacity *= 1 - engaged * 0.8 }
        let radius = min(shape.width, shape.height) * 0.28
        context.fill(
          Path(roundedRect: shape, cornerRadius: radius),
          with: .color(OverviewDataset.heatColor(value).opacity(opacity)))
      }
      if let cell, dataset.yearDays.indices.contains(cell) {
        let rect = layout.rect(index: cell).insetBy(dx: -0.5, dy: -0.5)
        context.stroke(
          Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) * 0.3),
          with: .color(Color.primary.opacity(0.7)), lineWidth: 1.5)
      }
      drawLabels(context, layout)
    }
  }

  private func drawLabels(_ context: GraphicsContext, _ layout: OverviewHeatLayout) {
    var lastColumn = -4
    // Days are zero-padded yyyy-MM-dd, so "-01" marks a month's first day without parsing.
    for (index, day) in dataset.yearDays.enumerated() where day.hasSuffix("-01") {
      let column = (layout.offset + index) / 7
      guard column >= lastColumn + 3 else { continue }
      lastColumn = column
      let text = Text(OverviewDay.month(day)).font(AIMTextRole.caption.font).foregroundStyle(.secondary)
      context.draw(text, at: CGPoint(x: layout.rect(index: index).minX, y: 0), anchor: .topLeading)
    }
    for (row, name) in [(1, "Mon"), (3, "Wed"), (5, "Fri")] {
      let text = Text(name).font(AIMTextRole.caption.font).foregroundStyle(.secondary)
      context.draw(text, at: CGPoint(x: 0, y: layout.rect(column: 0, row: row).midY), anchor: .leading)
    }
  }
}

struct OverviewHeatmap: View {
  let dataset: OverviewDataset
  /// A click on a day with usage; a zero-token day and a drag open nothing.
  var onSelect: (String) -> Void = { _ in }
  @State private var hover: OverviewHover?
  @State private var level: Int?
  @State private var lastLevel: Int?

  /// Width over height of the grid with its labels; the cells stay close to square.
  static let aspect: CGFloat = 6.6
  static let legendHeight: CGFloat = 16
  static let legendSpacing: CGFloat = 8

  var body: some View {
    VStack(alignment: .trailing, spacing: Self.legendSpacing) {
      GeometryReader { proxy in
        OverviewDrawIn(key: dataset.drawKey, duration: OverviewMotion.heatmap) { clock in
          OverviewHeatCanvas(
            dataset: dataset, clock: clock, engaged: hover == nil && level == nil ? 0 : 1,
            cell: hover?.index, level: level ?? lastLevel)
            .animation(OverviewMotion.hover, value: hover == nil && level == nil)
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
          switch phase {
          case .active(let point):
            hover = info(at: point, size: proxy.size)
            // The hand shows over a day that has a sheet, the arrow elsewhere.
            if let index = hover?.index, dataset.yearTotals[index] > 0 { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
          case .ended:
            hover = nil
            NSCursor.arrow.set()
          }
        }
        // A spatial tap ends only on a click, never on a drag.
        .gesture(SpatialTapGesture().onEnded { tap in
          let layout = OverviewHeatLayout(size: proxy.size, offset: dataset.yearOffset, count: dataset.yearDays.count)
          if let index = layout.index(at: tap.location), dataset.yearTotals[index] > 0 {
            // The sheet covers the chart and the pointer-left event never arrives: drop the tooltip first.
            hover = nil
            NSCursor.arrow.set()
            onSelect(dataset.yearDays[index])
          }
        })
        .overlay { OverviewTooltipLayer(hover: hover, size: proxy.size) }
        .onAppear {
          if let point = OverviewMotion.previewHover("heatmap", in: proxy.size) {
            hover = info(at: point, size: proxy.size)
          }
        }
      }
      .aspectRatio(Self.aspect, contentMode: .fit)
      .zIndex(1)
      legend
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(dataset.heatmapSummary)
    .accessibilityAddTraits(.isImage)
    .endsHover { hover = nil; level = nil }
  }

  private var legend: some View {
    HStack(spacing: 4) {
      Text("Less").aimText(.secondary)
      ForEach(0..<5, id: \.self) { value in
        RoundedRectangle(cornerRadius: 3, style: .continuous)
          .fill(OverviewDataset.heatColor(value))
          .frame(width: 12, height: 12)
          .onHover { inside in
            if inside { lastLevel = value }
            level = inside ? value : nil
          }
      }
      Text("More").aimText(.secondary)
    }
    .frame(height: Self.legendHeight)
  }

  private func info(at point: CGPoint, size: CGSize) -> OverviewHover? {
    let layout = OverviewHeatLayout(size: size, offset: dataset.yearOffset, count: dataset.yearDays.count)
    guard let index = layout.index(at: point) else { return nil }
    let tokens = dataset.yearTotals[index]
    // The tools that ran that day (at most three), then the day's total.
    let tools = dataset.yearTools.compactMap { tool -> OverviewTip.Row? in
      tool.daily.indices.contains(index) && tool.daily[index] > 0
        ? .init(
          color: nil, service: tool.service, label: OverviewDayDetail.toolName(tool.service),
          value: UsagePresentation.formatTokens(tool.daily[index]))
        : nil
    }
    let tip = OverviewTip(
      title: OverviewDay.long(dataset.yearDays[index]),
      rows: Array(tools.prefix(3))
        + [.init(color: nil, label: "Tokens", value: tokens == 0 ? "None" : UsagePresentation.formatTokens(tokens))])
    return OverviewHover(point: point, tip: tip, key: nil, index: index)
  }
}

// MARK: - Ridgeline

struct OverviewRidgeLayout {
  /// The band under the last ridge for the date axis.
  static let axis = OverviewDateAxis.height + 4
  /// How many pitches a peak stands: ridges overlap their neighbors by this much.
  static let overlap: CGFloat = 1.9
  static let margin: CGFloat = 4
  let size: CGSize
  let count: Int

  /// The ridges fill the plot: the first peak touches the top margin and the last baseline sits on
  /// the axis band. Fewer ridges get more spacing and taller peaks.
  private var span: CGFloat { max(size.height - Self.axis - 2 * Self.margin, 1) }
  var peak: CGFloat { count > 1 ? min(span / (CGFloat(count - 1) + Self.overlap) * Self.overlap, 150) : span }
  var pitch: CGFloat { count > 1 ? (span - peak) / CGFloat(count - 1) : 0 }
  /// The whole width: no label column, so the ridges start at the card's left edge.
  var plot: CGRect { CGRect(x: 0, y: 0, width: max(size.width, 1), height: size.height) }

  func baseline(_ row: Int) -> CGFloat { Self.margin + peak + CGFloat(row) * pitch }

  func x(_ day: Int, of days: Int) -> CGFloat {
    plot.minX + plot.width * CGFloat(day) / CGFloat(max(days - 1, 1))
  }

  /// The ridge a pointer is nearest to; the front ridges cover the rows above them.
  func row(at y: CGFloat) -> Int {
    (0..<count).min { abs(baseline($0) - peak * 0.25 - y) < abs(baseline($1) - peak * 0.25 - y) } ?? 0
  }
}

private struct OverviewRidgeCanvas: View, Animatable {
  let series: [OverviewSeries]
  let clock: Double
  var engaged: Double
  let highlight: String?
  let day: Int?
  var animatableData: Double {
    get { engaged }
    set { engaged = newValue }
  }

  var body: some View {
    Canvas { context, size in
      let layout = OverviewRidgeLayout(size: size, count: series.count)
      let days = series.first?.daily.count ?? 0
      guard days > 1 else { return }
      let stagger = min(0.1, 0.4 / Double(max(series.count, 1)))
      for (row, item) in series.enumerated() {
        let base = layout.baseline(row)
        let faded = highlight != nil && item.id != highlight
        let on = highlight == item.id
        let opacity = faded ? 1 - engaged * (1 - OverviewMotion.dimmed) : 1
        let rise = OverviewMotion.window(clock, start: Double(row) * stagger, length: 0.5)
        let lift = on ? 6 * engaged : 0
        let top = Double(item.daily.max() ?? 1)
        let points = item.daily.enumerated().map { index, value in
          CGPoint(
            x: layout.x(index, of: days),
            y: base - lift - layout.peak * rise * Double(value) / max(top, 1))
        }
        var line = Path()
        line.move(to: CGPoint(x: layout.plot.minX, y: base))
        line.addLine(to: CGPoint(x: layout.plot.maxX, y: base))
        context.stroke(line, with: .color(AIMTheme.hairline.opacity(0.6 * opacity)), lineWidth: 1)
        var ridge = Path()
        ridge.addMonotone(points, connect: false)
        var fill = ridge
        fill.addLine(to: CGPoint(x: layout.plot.maxX, y: base - lift))
        fill.addLine(to: CGPoint(x: layout.plot.minX, y: base - lift))
        fill.closeSubpath()
        // The card color first, so a ridge in front hides the one behind it.
        context.fill(fill, with: .color(AIMTheme.card))
        context.fill(
          fill,
          with: .linearGradient(
            Gradient(colors: [item.color.opacity(0.55 * opacity), item.color.opacity(0.05 * opacity)]),
            startPoint: CGPoint(x: 0, y: base - layout.peak), endPoint: CGPoint(x: 0, y: base)))
        context.stroke(ridge, with: .color(item.color.opacity(opacity)), lineWidth: 1.5)
        if on, let day, series[row].daily.indices.contains(day) {
          let point = points[day]
          var guide = Path()
          guide.move(to: CGPoint(x: point.x, y: base))
          guide.addLine(to: point)
          context.stroke(guide, with: .color(Color.primary.opacity(0.35 * engaged)), lineWidth: 1)
          context.fill(
            Path(ellipseIn: CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)),
            with: .color(item.color.opacity(engaged)))
        }
      }
    }
  }
}

struct OverviewRidgeline: View {
  let dataset: OverviewDataset
  @State private var hover: OverviewHover?
  @State private var lastKey: String?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// The ridges run the card's full width; the names sit in a one-line legend below, like Tokens per
  /// day. The legend highlights the hovered ridge's name. The plot is above the legend (zIndex), so
  /// its tooltip never draws under it.
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      GeometryReader { proxy in
        let layout = OverviewRidgeLayout(size: proxy.size, count: dataset.series.count)
        ZStack(alignment: .topLeading) {
          OverviewDrawIn(key: dataset.drawKey, duration: OverviewMotion.ridge) { clock in
            OverviewRidgeCanvas(
              series: dataset.series, clock: clock, engaged: hover == nil ? 0 : 1,
              highlight: hover?.key ?? lastKey, day: hover?.index)
              .animation(OverviewMotion.hover, value: hover == nil)
          }
          .contentShape(Rectangle())
          .onContinuousHover { phase in
            switch phase {
            case .active(let point):
              hover = info(at: point, layout: layout)
              if let key = hover?.key { lastKey = key }
            case .ended: hover = nil
            }
          }
          OverviewDateAxis(days: dataset.days, inset: AIMTheme.cardInset)
            .frame(width: layout.plot.width)
            .position(x: layout.plot.midX, y: proxy.size.height - OverviewDateAxis.height / 2)
            .allowsHitTesting(false)
          OverviewTooltipLayer(hover: hover, size: proxy.size)
        }
        .onAppear {
          if let point = OverviewMotion.previewHover("ridge", in: proxy.size) {
            hover = info(at: point, layout: layout)
            lastKey = hover?.key
          }
        }
      }
      .zIndex(1)
      OverviewLegend(series: dataset.series, active: hover?.key).padding(.horizontal, AIMTheme.cardInset)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(dataset.ridgeSummary)
    .accessibilityAddTraits(.isImage)
    .endsHover { hover = nil }
  }

  private func info(at point: CGPoint, layout: OverviewRidgeLayout) -> OverviewHover? {
    let days = dataset.days.count
    guard days > 1, !dataset.series.isEmpty, layout.plot.contains(CGPoint(x: point.x, y: layout.plot.midY)) else {
      return nil
    }
    let day = min(max(Int(((point.x - layout.plot.minX) / layout.plot.width * Double(days - 1)).rounded()), 0), days - 1)
    let item = dataset.series[layout.row(at: point.y)]
    let tip = OverviewTip(
      title: OverviewDay.short(dataset.days[day]),
      rows: [.init(
        color: item.color, service: item.service, label: item.tipLabel, value: UsagePresentation.formatTokens(item.daily[day]))])
    return OverviewHover(point: point, tip: tip, key: item.id, index: day)
  }
}

// MARK: - Waffle chart

private struct OverviewWaffleCanvas: View, Animatable {
  let owners: [Int]
  let series: [OverviewSeries]
  let clock: Double
  var engaged: Double
  let highlight: String?
  var animatableData: Double {
    get { engaged }
    set { engaged = newValue }
  }

  var body: some View {
    Canvas { context, size in
      let side = OverviewWaffle.cellSide(size.width)
      for (slot, owner) in owners.enumerated() {
        let rect = OverviewWaffle.rect(slot, side: side)
        // Cells fill in reading order.
        let arrive = OverviewMotion.window(clock, start: Double(slot) / Double(OverviewWaffle.total) * 0.5, length: 0.5)
        let scale = 0.6 + 0.4 * arrive
        let shape = rect.insetBy(dx: side * (1 - scale) / 2, dy: side * (1 - scale) / 2)
        let faded = highlight != nil && series[owner].id != highlight
        let opacity = arrive * (faded ? 1 - engaged * 0.75 : 1)
        context.fill(
          Path(roundedRect: shape, cornerRadius: side * 0.22),
          with: .color(series[owner].color.opacity(opacity)))
      }
    }
  }
}

enum OverviewWaffle {
  static let gap: CGFloat = 3
  static let columns = 20, rows = 10
  /// Every cell is half a percent.
  static let total = columns * rows
  /// The waffle's share of the card's content width; the legend gets the rest.
  static let share: CGFloat = 0.4
  static let legendGap: CGFloat = 24
  /// Legend rows spread over the waffle height between these heights.
  static let minRow: CGFloat = 20, maxRow: CGFloat = 28

  static func cellSide(_ width: CGFloat) -> CGFloat { max((width - gap * CGFloat(columns - 1)) / CGFloat(columns), 1) }
  /// The grid is as tall as its cells: ten rows of the side the width gives.
  static func height(width: CGFloat) -> CGFloat { cellSide(width) * CGFloat(rows) + gap * CGFloat(rows - 1) }
  static func rect(_ slot: Int, side: CGFloat) -> CGRect {
    CGRect(
      x: CGFloat(slot % columns) * (side + gap), y: CGFloat(slot / columns) * (side + gap), width: side, height: side)
  }

  /// The waffle and legend widths for a card content width.
  static func widths(_ width: CGFloat) -> (waffle: CGFloat, legend: CGFloat) {
    let free = max(width - legendGap, 0)
    return (free * share, free * (1 - share))
  }

  /// Largest-remainder rounding: whole cells that always add up to 200.
  static func cells(_ tokens: [Int64]) -> [Int] {
    let sum = tokens.reduce(0, +)
    guard sum > 0 else { return tokens.map { _ in 0 } }
    let exact = tokens.map { Double($0) * Double(total) / Double(sum) }
    var cells = exact.map { Int($0) }
    let spare = total - cells.reduce(0, +)
    let order = exact.indices.sorted { (exact[$0] - Double(cells[$0]), $1) > (exact[$1] - Double(cells[$1]), $0) }
    for index in order.prefix(spare) { cells[index] += 1 }
    return cells
  }

  /// The series that owns each of the 200 cells, in reading order.
  static func owners(_ cells: [Int]) -> [Int] {
    cells.enumerated().flatMap { Array(repeating: $0.offset, count: $0.element) }
  }

  /// Whole percents (two cells each); one cell, under 1%, reads "<1%".
  static func percent(_ cells: Int) -> String { cells < 2 ? "<1%" : "\(cells / 2)%" }
}

/// The waffle on the left (40% of the width) and the legend on the right (60%, after the gap). The
/// height follows the waffle, or the legend at its minimum row height when that is taller.
struct OverviewWaffleSplit: Layout {
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? 600
    let (left, right) = OverviewWaffle.widths(width)
    let legend = subviews.count > 1 ? subviews[1].sizeThatFits(ProposedViewSize(width: right, height: nil)).height : 0
    return CGSize(width: width, height: max(OverviewWaffle.height(width: left), legend))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let (left, right) = OverviewWaffle.widths(bounds.width)
    subviews[0].place(
      at: bounds.origin, anchor: .topLeading,
      proposal: ProposedViewSize(width: left, height: OverviewWaffle.height(width: left)))
    if subviews.count > 1 {
      subviews[1].place(
        at: CGPoint(x: bounds.maxX - right, y: bounds.minY), anchor: .topLeading,
        proposal: ProposedViewSize(width: right, height: bounds.height))
    }
  }
}

struct OverviewWaffleChart: View {
  let dataset: OverviewDataset
  @State private var hover: OverviewHover?
  @State private var legendKey: String?
  @State private var lastKey: String?

  var body: some View {
    let cells = OverviewWaffle.cells(dataset.series.map(\.tokens))
    let owners = OverviewWaffle.owners(cells)
    let active = hover?.key ?? legendKey
    OverviewWaffleSplit {
      GeometryReader { proxy in
        OverviewDrawIn(key: dataset.drawKey, duration: OverviewMotion.waffle) { clock in
          OverviewWaffleCanvas(
            owners: owners, series: dataset.series, clock: clock, engaged: active == nil ? 0 : 1,
            highlight: active ?? lastKey)
            .animation(OverviewMotion.hover, value: active == nil)
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
          switch phase {
          case .active(let point): hover = info(at: point, width: proxy.size.width, owners: owners, cells: cells)
          case .ended: hover = nil
          }
          if let key = hover?.key { lastKey = key }
        }
        .onAppear {
          if let point = OverviewMotion.previewHover("waffle", in: proxy.size) {
            hover = info(at: point, width: proxy.size.width, owners: owners, cells: cells)
            lastKey = hover?.key
          }
        }
      }
      VStack(spacing: 0) {
        ForEach(Array(dataset.series.enumerated()), id: \.element.id) { index, item in
          legendRow(item, cells: cells[index], active: active)
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    // The tooltip belongs to the whole split, not the grid: inside the grid it drew under the legend
    // (a later subview), which showed through it. The grid and the split share one origin.
    .overlay {
      GeometryReader { proxy in OverviewTooltipLayer(hover: hover, size: proxy.size, flips: false) }
        .allowsHitTesting(false)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(dataset.waffleSummary)
    .accessibilityAddTraits(.isImage)
    .endsHover { hover = nil; legendKey = nil }
  }

  private func legendRow(_ item: OverviewSeries, cells: Int, active: String?) -> some View {
    HStack(spacing: 8) {
      Circle().fill(item.color).frame(width: 8, height: 8)
      OverviewServiceTile(service: item.service, reserve: dataset.series.contains { $0.service != nil })
      Text(item.label).aimText(.body).lineLimit(1).truncationMode(.middle)
      Spacer(minLength: 12)
      Text(OverviewWaffle.percent(cells)).aimText(.body).monospacedDigit().aimRolling(cells)
        .uiLint(.number)
      Text(UsagePresentation.formatTokens(item.tokens)).aimText(.secondary).monospacedDigit()
        .frame(width: 56, alignment: .trailing)
    }
    .frame(minHeight: OverviewWaffle.minRow, maxHeight: OverviewWaffle.maxRow)
    .opacity(active == nil || active == item.id ? 1 : OverviewMotion.dimmed)
    .animation(AIMMotion.fade(AIMMotion.hover), value: active)
    .contentShape(Rectangle())
    .onHover { inside in legendKey = inside ? item.id : nil }
  }

  private func info(at point: CGPoint, width: CGFloat, owners: [Int], cells: [Int]) -> OverviewHover? {
    let side = OverviewWaffle.cellSide(width)
    let (columns, rows) = (OverviewWaffle.columns, OverviewWaffle.rows)
    guard point.x >= 0, point.y >= 0 else { return nil }
    let column = Int(point.x / (side + OverviewWaffle.gap)), row = Int(point.y / (side + OverviewWaffle.gap))
    guard (0..<columns).contains(column), (0..<rows).contains(row), owners.indices.contains(row * columns + column) else {
      return nil
    }
    let slot = row * columns + column
    let index = owners[slot]
    let item = dataset.series[index]
    let tip = OverviewTip(
      title: item.tipLabel, titleService: item.service,
      rows: [
        .init(color: item.color, label: "Share", value: OverviewWaffle.percent(cells[index])),
        .init(color: nil, label: "Tokens", value: UsagePresentation.formatTokens(item.tokens)),
      ])
    return OverviewHover(point: point, tip: tip, key: item.id, index: slot)
  }
}
