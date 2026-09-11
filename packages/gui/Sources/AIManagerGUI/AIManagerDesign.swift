import AppKit
import SwiftUI

enum AIMTheme {
  static let radius: CGFloat = 2
  static let railWidth: CGFloat = 48
  static let topbarHeight: CGFloat = 56
  static let listWidth: CGFloat = 200

  static let canvas = dynamic(light: 0xECEBE7, dark: 0x0B0C0F)
  static let rail = dynamic(light: 0xF4F3EF, dark: 0x101216)
  static let panel = dynamic(light: 0xFAF9F6, dark: 0x17191D)
  static let panel2 = dynamic(light: 0xF0EFEB, dark: 0x1D2025)
  static let panel3 = dynamic(light: 0xE5E4DF, dark: 0x262A30)
  static let line = dynamic(light: 0xD4D3CE, dark: 0x2A2E34)
  static let lineSoft = dynamic(light: 0xE2E1DC, dark: 0x22262B)
  static let ink = dynamic(light: 0x1A1B1D, dark: 0xEFEEE9)
  static let muted = dynamic(light: 0x666970, dark: 0x999CA3)
  static let faint = dynamic(light: 0x75787F, dark: 0x767A82)
  static let blue = dynamic(light: 0x566D95, dark: 0x8295B5)
  static let green = dynamic(light: 0x557D68, dark: 0x78A28B)
  static let amber = dynamic(light: 0x856F43, dark: 0xB39A68)
  static let red = dynamic(light: 0x8D5A60, dark: 0xAD7379)
  static let titleArt = dynamic(light: 0x657B98, dark: 0x92A7C3)
  static let titleTeal = dynamic(light: 0x638F8A, dark: 0x8DB8B0)
  static let active = Color(hex: 0x3C4A61)
  static let activeInk = Color(hex: 0xF2F1ED)
  static let railIdle = Color(hex: 0x91A0B2)
  static let statusInk = dynamic(light: 0xFFFFFF, dark: 0x0B0C0F)
  static let control = dynamic(light: 0xDEDCD6, dark: 0x1D2025)
  static let controlHover = dynamic(light: 0xD3D1CA, dark: 0x262A30)

  static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
    .custom("Geist-Regular", size: size).weight(weight)
  }

  static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
    .custom("GeistMono-Regular", size: size).weight(weight)
  }

  private static func dynamic(light: UInt32, dark: UInt32) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        Color(hex: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
          .nsColor
      })
  }
}

extension Color {
  fileprivate init(hex: UInt32) {
    self.init(
      .sRGB,
      red: Double((hex >> 16) & 0xff) / 255,
      green: Double((hex >> 8) & 0xff) / 255,
      blue: Double(hex & 0xff) / 255,
      opacity: 1
    )
  }

  fileprivate var nsColor: NSColor { NSColor(self) }
}

struct AIMIcon: View {
  enum Name {
    case mark, account, settings, history, recovery, plus, refresh, moon, sun, close, minimize,
      chevron, check, folder, play, copy, warning
  }
  let name: Name
  var size: CGFloat = 17

  var body: some View {
    AIMIconShape(name: name)
      .stroke(style: StrokeStyle(lineWidth: 1.65, lineCap: .round, lineJoin: .round))
      .frame(width: size, height: size)
      .accessibilityHidden(true)
  }
}

private struct AIMIconShape: Shape {
  let name: AIMIcon.Name
  func path(in rect: CGRect) -> Path {
    let sx = rect.width / 24
    let sy = rect.height / 24
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * sx, y: y * sy) }
    var path = Path()
    switch name {
    case .account:
      path.addEllipse(in: CGRect(x: 8 * sx, y: 4 * sy, width: 8 * sx, height: 8 * sy))
      path.move(to: p(4, 21))
      path.addCurve(to: p(20, 21), control1: p(4.6, 10.5), control2: p(19.4, 10.5))
    case .settings:
      path.addEllipse(in: CGRect(x: 9 * sx, y: 9 * sy, width: 6 * sx, height: 6 * sy))
      path.move(to: p(19, 12))
      path.addCurve(to: p(18.9, 11), control1: p(19, 11.7), control2: p(19, 11.3))
      path.addLine(to: p(21, 9.5))
      path.addLine(to: p(19, 6.1))
      path.addLine(to: p(16.6, 7))
      path.addCurve(to: p(14.9, 6), control1: p(16.1, 6.6), control2: p(15.5, 6.3))
      path.addLine(to: p(14.5, 3))
      path.addLine(to: p(9.5, 3))
      path.addLine(to: p(9.1, 5.5))
      path.addCurve(to: p(7.4, 6.5), control1: p(8.5, 5.7), control2: p(7.9, 6))
      path.addLine(to: p(5.1, 5.6))
      path.addLine(to: p(3.1, 9))
      path.addLine(to: p(5.1, 10.5))
      path.addCurve(to: p(5.1, 12.5), control1: p(5, 11.2), control2: p(5, 11.8))
      path.addLine(to: p(3.1, 14))
      path.addLine(to: p(5.1, 17.4))
      path.addLine(to: p(7.4, 16.5))
      path.addCurve(to: p(9.1, 17.5), control1: p(7.9, 17), control2: p(8.5, 17.3))
      path.addLine(to: p(9.5, 20))
      path.addLine(to: p(14.5, 20))
      path.addLine(to: p(14.9, 17))
      path.addCurve(to: p(16.6, 16), control1: p(15.5, 16), control2: p(16.1, 15.7))
      path.addLine(to: p(18.9, 16.9))
      path.addLine(to: p(20.9, 13.5))
      path.addLine(to: p(18.9, 12))
    case .history:
      path.move(to: p(4, 12))
      path.addCurve(to: p(20, 12), control1: p(4, 1.3), control2: p(20, 1.3))
      path.addCurve(to: p(4, 12), control1: p(20, 22.7), control2: p(4, 22.7))
      path.move(to: p(4, 7))
      path.addLine(to: p(4, 12))
      path.addLine(to: p(9, 12))
      path.move(to: p(12, 8))
      path.addLine(to: p(12, 12))
      path.addLine(to: p(15, 14))
    case .recovery, .refresh:
      path.move(to: p(20, 12))
      path.addCurve(to: p(4, 12), control1: p(20, 1.5), control2: p(4, 1.5))
      path.addCurve(to: p(17.7, 6.3), control1: p(4, 22.5), control2: p(16.2, 22.5))
      path.move(to: p(20, 4))
      path.addLine(to: p(20, 9))
      path.addLine(to: p(15, 9))
    case .plus:
      path.move(to: p(12, 5))
      path.addLine(to: p(12, 19))
      path.move(to: p(5, 12))
      path.addLine(to: p(19, 12))
    case .moon:
      path.move(to: p(20, 14.5))
      path.addCurve(to: p(9.5, 4), control1: p(14, 16), control2: p(8, 10))
      path.addCurve(to: p(20, 14.5), control1: p(4, 12), control2: p(12, 22))
    case .sun:
      path.addEllipse(in: CGRect(x: 8 * sx, y: 8 * sy, width: 8 * sx, height: 8 * sy))
      for (a, b, c, d) in [
        (12, 2, 12, 4), (12, 20, 12, 22), (2, 12, 4, 12), (20, 12, 22, 12), (4.9, 4.9, 6.3, 6.3),
        (17.7, 17.7, 19.1, 19.1), (4.9, 19.1, 6.3, 17.7), (17.7, 6.3, 19.1, 4.9),
      ] {
        path.move(to: p(CGFloat(a), CGFloat(b)))
        path.addLine(to: p(CGFloat(c), CGFloat(d)))
      }
    case .close:
      path.move(to: p(6, 6))
      path.addLine(to: p(18, 18))
      path.move(to: p(18, 6))
      path.addLine(to: p(6, 18))
    case .minimize:
      path.move(to: p(5, 12))
      path.addLine(to: p(19, 12))
    case .chevron:
      path.move(to: p(9, 6))
      path.addLine(to: p(15, 12))
      path.addLine(to: p(9, 18))
    case .check:
      path.move(to: p(5, 12))
      path.addLine(to: p(10, 17))
      path.addLine(to: p(19, 7))
    case .folder:
      path.move(to: p(3, 7))
      path.addCurve(to: p(5, 5), control1: p(3, 6), control2: p(4, 5))
      path.addLine(to: p(9, 5))
      path.addLine(to: p(11, 7))
      path.addLine(to: p(19, 7))
      path.addCurve(to: p(21, 9), control1: p(20, 7), control2: p(21, 8))
      path.addLine(to: p(21, 18))
      path.addCurve(to: p(19, 20), control1: p(21, 19), control2: p(20, 20))
      path.addLine(to: p(5, 20))
      path.addCurve(to: p(3, 18), control1: p(4, 20), control2: p(3, 19))
      path.closeSubpath()
    case .play:
      path.move(to: p(7, 4))
      path.addLine(to: p(7, 20))
      path.addLine(to: p(20, 12))
      path.closeSubpath()
    case .copy:
      path.addRect(CGRect(x: 8 * sx, y: 8 * sy, width: 12 * sx, height: 12 * sy))
      path.move(to: p(16, 8))
      path.addLine(to: p(16, 4))
      path.addLine(to: p(4, 4))
      path.addLine(to: p(4, 16))
      path.addLine(to: p(8, 16))
    case .warning:
      path.move(to: p(12, 3))
      path.addLine(to: p(2, 20))
      path.addLine(to: p(22, 20))
      path.closeSubpath()
      path.move(to: p(12, 10))
      path.addLine(to: p(12, 14))
      path.move(to: p(12, 17))
      path.addLine(to: p(12.01, 17))
    case .mark:
      path.addRect(CGRect(x: 5 * sx, y: 5 * sy, width: 14 * sx, height: 14 * sy))
      path.move(to: p(5, 10))
      path.addLine(to: p(19, 10))
      path.move(to: p(10, 5))
      path.addLine(to: p(11, 10))
      path.move(to: p(10.5, 13))
      path.addLine(to: p(10.5, 17))
      path.addLine(to: p(15.5, 15))
      path.closeSubpath()
    }
    return path
  }
}

struct AIMPanel<Content: View>: View {
  let title: String
  @ViewBuilder var content: Content
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        Text(title)
          .font(AIMTheme.sans(12, weight: .semibold))
          .padding(.horizontal, 16)
          .frame(height: 40)
          .background(alignment: .trailing) { AIMPanelArcs().frame(width: 200, height: 40) }
          .background(AIMTheme.panel2)
          .clipped()
        Spacer(minLength: 0)
      }
      .frame(height: 40).background(AIMTheme.panel2)
      content
    }
    .background(AIMTheme.panel)
    .clipShape(RoundedRectangle(cornerRadius: AIMTheme.radius))
  }
}

private struct AIMPanelArcs: View {
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    HStack(spacing: 0) {
      Spacer(minLength: 0)
      ZStack {
        LinearGradient(
          stops: [
            .init(color: AIMTheme.titleTeal.opacity(scheme == .dark ? 0.195 : 0.156), location: 0),
            .init(color: .clear, location: 0.48),
            .init(color: AIMTheme.titleArt.opacity(scheme == .dark ? 0.30 : 0.24), location: 1),
          ],
          startPoint: UnitPoint(x: 0.14, y: 1),
          endPoint: UnitPoint(x: 0.86, y: 0)
        )
        Canvas { context, _ in
          for (center, opacity) in [(CGPoint(x: 187, y: 47), 1.0), (CGPoint(x: 128, y: -23), 0.6)] {
            for radius in [CGFloat(24), 33, 42, 51, 60] {
              let rect = CGRect(
                x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
              context.stroke(
                Path(ellipseIn: rect), with: .color(AIMTheme.titleArt.opacity(0.48 * opacity)),
                lineWidth: 0.65)
            }
          }
        }
        .mask(
          LinearGradient(
            stops: [
              .init(color: .white.opacity(0.22), location: 0),
              .init(color: .white.opacity(0.6), location: 0.55), .init(color: .white, location: 1),
            ], startPoint: .leading, endPoint: .trailing)
        )
      }
      .frame(width: 200, height: 40)
    }
  }
}
