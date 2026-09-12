import AppKit

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

@MainActor
enum AIManagerNativeContract {
  // Acceptance points use the screenshot's top-left origin; AppKit content views usually do not.
  static func titleDragTarget(in window: NSWindow, at point: NSPoint) -> Bool {
    guard let contentView = window.contentView else { return false }
    return hitTest(in: contentView, atTopOriginPoint: point) is AIMTitleDragView
  }

  static func focusPolicyMatches(in root: NSView, indicatorsEnabled: Bool) -> Bool {
    root.focusRingType == (indicatorsEnabled ? .default : .none)
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
      $0.scrollerStyle == .overlay && $0.autohidesScrollers
        && $0.verticalScroller is AIMThinScroller
    }.count
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
