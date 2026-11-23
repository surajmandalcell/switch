import AppKit
import SwiftUI

/// The shared About design (OnePlusUI 1.4 `OnePlusAboutMetrics`), drawn with Switch's own parts:
/// OnePlusUI needs macOS 15 and Switch supports macOS 14.
private enum AboutMetrics {
  static let window = CGSize(width: 380, height: 480)
  static let heroTop: CGFloat = 10
  static let heroIcon: CGFloat = 84
  static let heroIconShadow = (opacity: 0.18, radius: CGFloat(8), y: CGFloat(4))
  static let heroTitleTop: CGFloat = 10
  static let taglineTop: CGFloat = 3
  static let versionTop: CGFloat = 6
  static let buttonsTop: CGFloat = 14
  static let linkArrowGap: CGFloat = 4
  static let windowIcon: CGFloat = 104
  static let windowIconShadow = (opacity: 0.25, radius: CGFloat(14), y: CGFloat(7))
  static let windowButtonsTop: CGFloat = 20
  static let windowGutter: CGFloat = 24
  static let footerBottom: CGFloat = 18
  static let updateGlyphGap: CGFloat = 5
  static let fieldHeight: CGFloat = 230
  static let fieldBlurIcon: CGFloat = 460
  static let fieldBlur: CGFloat = 60
  static let fieldIconOpacity = (light: 0.3, dark: 0.45)
  static let fieldTintOpacity = (first: 0.4, second: 0.3)
  static let fieldTintRadius = (first: CGFloat(260), second: CGFloat(240))
  static let glow: CGFloat = 200
  static let glowOpacity = (min: 0.35, max: 0.55)
  static let glowBreath = 2.4
}

struct AboutLink: Identifiable {
  let label: String
  let title: String
  let url: URL
  var id: String { label + title }
}

@MainActor
enum SwitchAbout {
  /// The About window's Animation setting. Reduce Motion always stops the glow.
  nonisolated static let animationKey = "aboutAnimation"
  static let tagline = "Coding accounts and usage. Right in your menu bar."
  static let copyright = "© 2026 Suraj Mandal"
  private static let repository = URL(string: "https://github.com/surajmandalcell/switch")!
  static let website = AboutLink(label: "Website", title: "switch.samhq.app", url: URL(string: "https://switch.samhq.app")!)
  static let releaseNotes = AboutLink(
    label: "Release notes", title: "GitHub releases", url: repository.appendingPathComponent("releases"))
  static let license = AboutLink(
    label: "License", title: "MIT license", url: repository.appendingPathComponent("blob/master/LICENSE"))
  static let links = [
    website, releaseNotes,
    AboutLink(label: "Report a problem", title: "GitHub issues", url: repository.appendingPathComponent("issues")),
    license,
  ]
  static let credits = [
    AboutLink(label: "OpenUsage", title: "Usage adapters", url: URL(string: "https://github.com/robinebers/openusage")!),
    AboutLink(label: "CodexBar", title: "Usage adapters", url: URL(string: "https://github.com/steipete/CodexBar")!),
  ]

  static var name: String { AIManagerBrand.bundleDisplayName() }
  static var icon: NSImage { NSApp.applicationIconImage ?? NSImage() }
  static var versionLine: String {
    let version = UpdateChecker.installedVersion
    return version.isEmpty ? "Version unknown" : "Version \(version)"
  }

  static func updateLine(_ updates: UpdateChecker) -> String {
    guard let available = updates.available else { return versionLine }
    return "\(versionLine)  ·  Version \(available.version) is available"
  }

  /// The icon's two most colorful points, for the color field and glow.
  static let tints: [Color] = {
    let side = 8
    guard let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return [.accentColor, .accentColor] }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
    NSGraphicsContext.restoreGraphicsState()
    var pixels: [NSColor] = []
    for x in 0..<side {
      for y in 0..<side {
        if let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.6 { pixels.append(color) }
      }
    }
    guard !pixels.isEmpty else { return [.accentColor, .accentColor] }
    let sorted = pixels.sorted {
      $0.saturationComponent * $0.brightnessComponent > $1.saturationComponent * $1.brightnessComponent
    }
    return [sorted[0], sorted[sorted.count / 5]].map { Color(nsColor: $0) }
  }()

  static func open(_ url: URL) { NSWorkspace.shared.open(url) }

  private static var window: NSWindow?

  /// One About window: fixed size, close button only, its last position restored before it shows.
  static func show() {
    if let window {
      window.makeKeyAndOrderFront(nil)
      NSApp.activate()
      return
    }
    let host = NSHostingController(rootView: SwitchAboutWindow().ignoresSafeArea()
      .focusEffectDisabled(!AIMFocus.showsSystemRings))
    host.sizingOptions = []
    let size = AboutMetrics.window
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.contentViewController = host
    window.setContentSize(size)
    window.identifier = NSUserInterfaceItemIdentifier("about")
    window.title = "About \(name)"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isMovableByWindowBackground = true
    window.isReleasedWhenClosed = false
    window.backgroundColor = AIMTheme.pageColor
    window.standardWindowButton(.miniaturizeButton)?.isHidden = true
    window.standardWindowButton(.zoomButton)?.isHidden = true
    window.center()
    window.setFrameAutosaveName("SwitchAboutWindow")
    if let screen = window.screen ?? NSScreen.main, !screen.visibleFrame.contains(window.frame) { window.center() }
    Self.window = window
    window.makeKeyAndOrderFront(nil)
    NSApp.activate()
  }
}

// MARK: - About window: the color field (free app)

private struct SwitchAboutWindow: View {
  @ObservedObject private var updates = UpdateChecker.shared

  var body: some View {
    VStack(spacing: 0) {
      AboutColorField()
      Text(SwitchAbout.name).aimText(.title)
      Text(SwitchAbout.tagline).aimText(.secondary).multilineTextAlignment(.center)
        .padding(.horizontal, AboutMetrics.windowGutter).padding(.top, AboutMetrics.taglineTop + 1)
      Text(SwitchAbout.updateLine(updates)).aimText(.secondary).padding(.top, AboutMetrics.versionTop + 2)
      HStack(spacing: AIMTheme.rowSpacing) {
        if updates.available != nil {
          AIMButton(title: "Download update", tone: .primary, action: updates.openDownload)
        }
        AIMButton(title: "Website") { SwitchAbout.open(SwitchAbout.website.url) }
        AIMButton(title: "License") { SwitchAbout.open(SwitchAbout.license.url) }
      }
      .padding(.top, AboutMetrics.windowButtonsTop)
      Spacer(minLength: 0)
      Text(SwitchAbout.copyright).aimText(.secondary).padding(.bottom, AboutMetrics.footerBottom)
    }
    .frame(width: AboutMetrics.window.width, height: AboutMetrics.window.height)
    .background(AIMTheme.page)
  }
}

/// A blurred copy of the icon plus two icon tints, faded into the window, with the breathing glow.
private struct AboutColorField: View {
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let tints = SwitchAbout.tints
    let icon = SwitchAbout.icon
    ZStack {
      ZStack {
        Image(nsImage: icon).resizable().frame(width: AboutMetrics.fieldBlurIcon, height: AboutMetrics.fieldBlurIcon)
          .blur(radius: AboutMetrics.fieldBlur)
          .opacity(scheme == .dark ? AboutMetrics.fieldIconOpacity.dark : AboutMetrics.fieldIconOpacity.light)
        RadialGradient(
          colors: [tints[0].opacity(AboutMetrics.fieldTintOpacity.first), .clear],
          center: UnitPoint(x: 0.2, y: 0.1), startRadius: 0, endRadius: AboutMetrics.fieldTintRadius.first)
        RadialGradient(
          colors: [tints[1].opacity(AboutMetrics.fieldTintOpacity.second), .clear],
          center: UnitPoint(x: 0.85, y: 0.2), startRadius: 0, endRadius: AboutMetrics.fieldTintRadius.second)
      }
      .frame(maxWidth: .infinity).frame(height: AboutMetrics.fieldHeight).clipped()
      .mask(LinearGradient(colors: [.black, .black, .clear], startPoint: .top, endPoint: .bottom))
      AboutGlow(tint: tints[0])
      AboutIcon(size: AboutMetrics.windowIcon, shadow: AboutMetrics.windowIconShadow)
    }
    .frame(maxWidth: .infinity).frame(height: AboutMetrics.fieldHeight).clipped()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(SwitchAbout.name) icon")
  }
}

/// A soft radial glow in the icon's tint. It breathes while the Animation setting is on and Reduce Motion is off.
private struct AboutGlow: View {
  let tint: Color
  @AppStorage(SwitchAbout.animationKey) private var animates = true
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.controlActiveState) private var active
  @State private var bright = false

  private var breathing: Bool { animates && !reduceMotion && active != .inactive && AIMMotion.isLive }

  var body: some View {
    Circle()
      .fill(RadialGradient(
        colors: [tint.opacity(AboutMetrics.glowOpacity.max), .clear], center: .center,
        startRadius: 0, endRadius: AboutMetrics.glow / 2))
      .frame(width: AboutMetrics.glow, height: AboutMetrics.glow)
      .opacity(bright ? 1 : AboutMetrics.glowOpacity.min / AboutMetrics.glowOpacity.max)
      .onAppear { breathe(breathing) }
      .onChange(of: breathing) { _, on in breathe(on) }
  }

  private func breathe(_ on: Bool) {
    if on {
      withAnimation(.easeInOut(duration: AboutMetrics.glowBreath).repeatForever(autoreverses: true)) { bright = true }
    } else {
      withAnimation(nil) { bright = false }
    }
  }
}

private struct AboutIcon: View {
  let size: CGFloat
  let shadow: (opacity: Double, radius: CGFloat, y: CGFloat)

  var body: some View {
    Image(nsImage: SwitchAbout.icon).resizable().interpolation(.high).frame(width: size, height: size)
      .shadow(color: .black.opacity(shadow.opacity), radius: shadow.radius, y: shadow.y)
      .accessibilityHidden(true)
  }
}

// MARK: - Settings > About: the centered hero

/// The last part of Settings: icon hero, Links, Credits, the About window Animation switch, copyright.
struct SwitchAboutSettings: View {
  @ObservedObject private var updates = UpdateChecker.shared
  @AppStorage(SwitchAbout.animationKey) private var animates = true

  var body: some View {
    VStack(spacing: AIMTheme.cardGap) {
      hero
      AIMSection("Links") {
        ForEach(SwitchAbout.links) { AboutLinkRow(link: $0) }
      }
      AIMSection("Credits") {
        ForEach(SwitchAbout.credits) { AboutLinkRow(link: $0) }
      }
      AIMSection("About window") {
        Toggle(isOn: $animates) {
          Text("Animation")
          Text("The glow behind the icon breathes slowly.").aimText(.secondary)
        }
      }
      Text(SwitchAbout.copyright).aimText(.secondary)
    }
  }

  private var hero: some View {
    VStack(spacing: 0) {
      AboutIcon(size: AboutMetrics.heroIcon, shadow: AboutMetrics.heroIconShadow)
      Text(SwitchAbout.name).aimText(.title).padding(.top, AboutMetrics.heroTitleTop)
      Text(SwitchAbout.tagline).aimText(.secondary).padding(.top, AboutMetrics.taglineTop)
      Text(SwitchAbout.updateLine(updates)).aimText(.secondary).padding(.top, AboutMetrics.versionTop)
      HStack(spacing: AIMTheme.rowSpacing) {
        if updates.available != nil {
          AIMButton(title: "Download update", tone: .primary, action: updates.openDownload)
        }
        AIMButton(title: "What's New") { SwitchAbout.open(SwitchAbout.releaseNotes.url) }
      }
      .padding(.top, AboutMetrics.buttonsTop)
    }
    .frame(maxWidth: .infinity)
    .padding(.top, AboutMetrics.heroTop)
  }
}

private struct AboutLinkRow: View {
  let link: AboutLink

  var body: some View {
    LabeledContent {
      Button { SwitchAbout.open(link.url) } label: {
        HStack(spacing: AboutMetrics.linkArrowGap) {
          Text(verbatim: link.title).aimText(.secondary).lineLimit(1)
          Image(systemName: "arrow.up.right").aimFont(.caption).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(link.url.absoluteString)
    } label: {
      Text(link.label)
    }
  }
}
