import AIManagerCore
import Charts
import SwiftUI

// Compact daily bar chart for a `UsageChart` in the account detail. Menu cards never show charts.

enum UsageChartPresentation {
  /// A value in the chart's unit. Tokens use the compact form ("1.2M") unless `exact` is set.
  static func value(_ chart: UsageChart, _ value: Double, exact: Bool = false) -> String {
    guard chart.unit == "tokens", !exact else { return chart.format(value) }
    return UsagePresentation.formatTokens(Int64(min(max(value, 0), 9e15)))
  }

  /// "30 days, total $12.40, peak $2.10 on Oct 3": the VoiceOver value.
  static func summary(_ chart: UsageChart) -> String {
    let days = chart.points.count
    var text = "\(days) \(days == 1 ? "day" : "days"), total \(value(chart, chart.total, exact: true))"
    if let peak = chart.peak, peak.value > 0 {
      text += ", peak \(value(chart, peak.value, exact: true)) on \(peak.label)"
    }
    return text
  }

  /// Right side of the header: the exact value of the focused day, else the total.
  static func headline(_ chart: UsageChart, selected: UsagePoint?) -> String {
    if let selected { return "\(selected.label) · \(value(chart, selected.value))" }
    return "Total \(value(chart, chart.total))"
  }

  /// Minimal x axis: first, middle, and last day.
  static func axisLabels(_ chart: UsageChart) -> [String] { axisTicks(chart).map(\.label) }

  /// The labelled days, with their bar index.
  static func axisTicks(_ chart: UsageChart) -> [(index: Int, label: String)] {
    let last = chart.points.count - 1
    let picks = chart.points.count > 3 ? [0, chart.points.count / 2, last] : Array(chart.points.indices)
    return picks.map { ($0, chart.points[$0].label) }
  }

  /// Index after a left (-1) or right (+1) arrow, starting from the newest day.
  static func moved(_ index: Int?, by step: Int, count: Int) -> Int {
    min(max((index ?? count) + step, 0), max(count - 1, 0))
  }
}

struct UsageChartView: View {
  let chart: UsageChart
  var height: CGFloat = 72
  @State private var hoveredLabel: String?
  @State private var keyIndex: Int?
  @FocusState private var focused: Bool

  private var selected: UsagePoint? {
    if let hoveredLabel, let point = chart.points.first(where: { $0.label == hoveredLabel }) { return point }
    if focused, let keyIndex, chart.points.indices.contains(keyIndex) { return chart.points[keyIndex] }
    return nil
  }

  static let axisHeight: CGFloat = 14

  /// The first, middle, and last day under the bars. Charts gives an axis label only its own bar's
  /// width (about 10 pt in 30 bars), which cut "Sep 16" to "Sep…". These labels keep their natural
  /// width; the first starts at the left edge and the last ends at the right edge, and the middle
  /// one centers under its bar.
  private var axis: some View {
    GeometryReader { proxy in
      let count = CGFloat(max(chart.points.count, 1))
      ForEach(UsageChartPresentation.axisTicks(chart), id: \.index) { tick in
        let edge = tick.index == 0 ? Alignment.leading : tick.index == chart.points.count - 1 ? .trailing : .center
        Text(tick.label).aimText(.secondary).lineLimit(1).fixedSize()
          .frame(width: proxy.size.width, alignment: edge)
          .offset(x: edge == .center ? (CGFloat(tick.index) + 0.5) / count * proxy.size.width - proxy.size.width / 2 : 0)
      }
    }
    .accessibilityHidden(true)
  }

  var body: some View {
    let chosen = selected
    VStack(alignment: .leading, spacing: AIMTheme.rowSpacing) {
      HStack(alignment: .firstTextBaseline, spacing: AIMTheme.rowSpacing) {
        Text(chart.title).aimText(.body).lineLimit(1)
        Spacer(minLength: AIMTheme.rowSpacing)
        Text(UsageChartPresentation.headline(chart, selected: chosen))
          .aimText(.secondary, tint: chosen == nil ? nil : .primary).monospacedDigit()
          .lineLimit(1)
      }
      Chart(chart.points, id: \.label) { point in
        BarMark(x: .value("Day", point.label), y: .value(chart.unit, point.value))
          .cornerRadius(1.5)
          .foregroundStyle(AIMTheme.blue.opacity(chosen == nil || chosen?.label == point.label ? 1 : 0.4))
      }
      .chartXSelection(value: $hoveredLabel)
      .chartLegend(.hidden)
      .chartYAxis(.hidden)
      .chartXAxis(.hidden)
      .frame(height: height - Self.axisHeight - 4)
      axis.frame(height: Self.axisHeight)
    }
    .frame(maxWidth: .infinity)
    .focusable()
    .focused($focused)
    .onKeyPress(.leftArrow) { keyIndex = UsageChartPresentation.moved(keyIndex, by: -1, count: chart.points.count); return .handled }
    .onKeyPress(.rightArrow) { keyIndex = UsageChartPresentation.moved(keyIndex, by: 1, count: chart.points.count); return .handled }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(chart.title)
    .accessibilityValue(UsageChartPresentation.summary(chart))
  }
}
