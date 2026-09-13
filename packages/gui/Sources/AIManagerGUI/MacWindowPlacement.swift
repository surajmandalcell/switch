import AppKit
import CoreGraphics

struct AIManagerDisplayDescriptor: Equatable {
  let identifier: String
  let name: String
  let frame: NSRect
  let visibleFrame: NSRect
}

struct AIManagerStoredWindowPlacement: Codable, Equatable {
  let version: Int
  let displayIdentifier: String
  let displayName: String
  let displayFrameX: Double
  let displayFrameY: Double
  let displayFrameWidth: Double
  let displayFrameHeight: Double
  let leftOffset: Double
  let topOffset: Double

  var displayFrame: NSRect {
    NSRect(
      x: displayFrameX, y: displayFrameY,
      width: displayFrameWidth, height: displayFrameHeight)
  }
}

enum AIManagerWindowRestoreOutcome: Equatable {
  case restored
  case savedDisplayUnavailable
  case noSavedPlacement
}

enum AIManagerWindowPlacement {
  static let defaultsKey = "Switch.mainWindowPlacement.v1"

  @MainActor
  static func restore(
    _ window: NSWindow,
    autosaveName: String,
    defaults: UserDefaults = .standard
  ) -> AIManagerWindowRestoreOutcome {
    let displays = NSScreen.screens.map(descriptor)
    let savedPlacement: AIManagerStoredWindowPlacement?
    if let saved = load(defaults: defaults) {
      savedPlacement = saved
    } else if let legacy = defaults.string(forKey: "NSWindow Frame \(autosaveName)") {
      savedPlacement = legacyPlacement(from: legacy, displays: displays)
    } else {
      return .noSavedPlacement
    }

    guard let savedPlacement else { return .savedDisplayUnavailable }
    guard let display = matchingDisplay(for: savedPlacement, in: displays),
      let frame = restoredFrame(
        for: savedPlacement, windowSize: window.frame.size, displays: displays)
    else { return .savedDisplayUnavailable }

    window.setFrame(frame, display: false)
    store(placement(for: frame, on: display), defaults: defaults)
    return .restored
  }

  @MainActor
  static func save(_ window: NSWindow, defaults: UserDefaults = .standard) {
    let displays = NSScreen.screens.map(descriptor)
    guard let display = window.screen.map(descriptor)
      ?? display(containingMostOf: window.frame, in: displays)
    else { return }
    store(placement(for: window.frame, on: display), defaults: defaults)
  }

  static func placement(
    for windowFrame: NSRect,
    on display: AIManagerDisplayDescriptor
  ) -> AIManagerStoredWindowPlacement {
    AIManagerStoredWindowPlacement(
      version: 1,
      displayIdentifier: display.identifier,
      displayName: display.name,
      displayFrameX: display.frame.minX,
      displayFrameY: display.frame.minY,
      displayFrameWidth: display.frame.width,
      displayFrameHeight: display.frame.height,
      leftOffset: windowFrame.minX - display.visibleFrame.minX,
      topOffset: display.visibleFrame.maxY - windowFrame.maxY)
  }

  static func restoredFrame(
    for placement: AIManagerStoredWindowPlacement,
    windowSize: NSSize,
    displays: [AIManagerDisplayDescriptor]
  ) -> NSRect? {
    guard let display = matchingDisplay(for: placement, in: displays) else { return nil }
    let visible = display.visibleFrame
    let proposed = NSPoint(
      x: visible.minX + placement.leftOffset,
      y: visible.maxY - placement.topOffset - windowSize.height)
    let maximumX = max(visible.minX, visible.maxX - windowSize.width)
    let maximumY = max(visible.minY, visible.maxY - windowSize.height)
    return NSRect(
      origin: NSPoint(
        x: min(max(proposed.x, visible.minX), maximumX),
        y: min(max(proposed.y, visible.minY), maximumY)),
      size: windowSize)
  }

  static func legacyPlacement(
    from value: String,
    displays: [AIManagerDisplayDescriptor]
  ) -> AIManagerStoredWindowPlacement? {
    let values = value.split(whereSeparator: { $0.isWhitespace }).compactMap { Double($0) }
    guard values.count >= 8 else { return nil }
    let windowFrame = NSRect(x: values[0], y: values[1], width: values[2], height: values[3])
    let legacyDisplayFrame = NSRect(
      x: values[4], y: values[5], width: values[6], height: values[7])
    guard let display = legacyDisplay(for: legacyDisplayFrame, in: displays) else { return nil }
    return placement(for: windowFrame, on: display)
  }

  static func store(
    _ placement: AIManagerStoredWindowPlacement,
    defaults: UserDefaults = .standard
  ) {
    guard let data = try? JSONEncoder().encode(placement) else { return }
    defaults.set(data, forKey: defaultsKey)
  }

  static func load(defaults: UserDefaults = .standard) -> AIManagerStoredWindowPlacement? {
    guard let data = defaults.data(forKey: defaultsKey) else { return nil }
    return try? JSONDecoder().decode(AIManagerStoredWindowPlacement.self, from: data)
  }

  private static func matchingDisplay(
    for placement: AIManagerStoredWindowPlacement,
    in displays: [AIManagerDisplayDescriptor]
  ) -> AIManagerDisplayDescriptor? {
    displays.first(where: { $0.identifier == placement.displayIdentifier })
      ?? displays.first(where: { $0.name == placement.displayName })
  }

  private static func display(
    containingMostOf frame: NSRect,
    in displays: [AIManagerDisplayDescriptor]
  ) -> AIManagerDisplayDescriptor? {
    guard let display = displays.max(by: {
      intersectionArea($0.frame, frame) < intersectionArea($1.frame, frame)
    }), intersectionArea(display.frame, frame) > 0 else { return nil }
    return display
  }

  private static func legacyDisplay(
    for legacyFrame: NSRect,
    in displays: [AIManagerDisplayDescriptor]
  ) -> AIManagerDisplayDescriptor? {
    let ranked = displays.map { display in
      let overlap = intersectionArea(display.frame, legacyFrame)
      let overlapFraction = overlap / max(legacyFrame.width * legacyFrame.height, 1)
      let sizeDifference =
        abs(display.frame.width - legacyFrame.width)
        + abs(display.frame.height - legacyFrame.height)
      return (display: display, overlapFraction: overlapFraction, sizeDifference: sizeDifference)
    }.sorted {
      if abs($0.overlapFraction - $1.overlapFraction) > 0.001 {
        return $0.overlapFraction > $1.overlapFraction
      }
      return $0.sizeDifference < $1.sizeDifference
    }
    guard let best = ranked.first, best.overlapFraction >= 0.5 else { return nil }
    return best.display
  }

  private static func intersectionArea(_ left: NSRect, _ right: NSRect) -> CGFloat {
    let intersection = left.intersection(right)
    return intersection.isNull ? 0 : intersection.width * intersection.height
  }

  @MainActor
  private static func descriptor(for screen: NSScreen) -> AIManagerDisplayDescriptor {
    let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    let displayID = number.map { CGDirectDisplayID($0.uint32Value) }
    let identity = displayID.map {
      "\(CGDisplayVendorNumber($0)):\(CGDisplayModelNumber($0)):\(CGDisplaySerialNumber($0)):\(CGDisplayUnitNumber($0))"
    } ?? "unknown"
    return AIManagerDisplayDescriptor(
      identifier: "\(identity):\(screen.localizedName)",
      name: screen.localizedName,
      frame: screen.frame,
      visibleFrame: screen.visibleFrame)
  }
}
