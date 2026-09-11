import AppKit
import SwiftUI

@main
struct NativeScrollCheck {
  @MainActor
  static func main() async {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let size = NSSize(width: 240, height: 100)
    let content = AIMScrollView {
      VStack(spacing: 0) {
        ForEach(0..<80, id: \.self) { index in
          Text("Demo row \(index)").frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
        }
      }
    }
    .frame(width: size.width, height: size.height)

    let host = NSHostingView(rootView: content)
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(
      contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    try? await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()

    let scrollView: AIMOwnedScrollView = expect(
      descendants(of: host).compactMap({ $0 as? AIMOwnedScrollView }).first,
      "AIMOwnedScrollView was not installed"
    )
    let documentView: NSView = expect(scrollView.documentView, "The scroll view has no document")
    let clipView = scrollView.contentView
    scrollView.layoutSubtreeIfNeeded()
    documentView.layoutSubtreeIfNeeded()

    expect(scrollView.scrollerStyle == .overlay, "The scrollbar is not an overlay")
    expect(scrollView.verticalScroller is AIMThinScroller, "The owned thin scrollbar is missing")
    expect(
      AIMThinScroller.scrollerWidth(for: .mini, scrollerStyle: .overlay) == 3,
      "The native scrollbar is not 3 px"
    )
    expect(documentView.frame.height > clipView.bounds.height, "Document does not overflow")
    expect(
      abs(documentView.frame.width - clipView.bounds.width) < 0.5,
      "Overlay scrollbar reserves a content gutter"
    )

    let bottomY = max(0, documentView.frame.height - clipView.bounds.height)
    clipView.scroll(to: NSPoint(x: 0, y: bottomY))
    scrollView.reflectScrolledClipView(clipView)
    let scrolledY = clipView.bounds.minY
    expect(scrolledY > 0, "Programmatic scrolling did not advance")
    host.layoutSubtreeIfNeeded()
    scrollView.layoutSubtreeIfNeeded()
    expect(abs(clipView.bounds.minY - scrolledY) < 0.5, "Layout reset the scroll position")
    expect(
      clipView.bounds.maxY >= documentView.frame.maxY - 0.5,
      "The bottom of the document is unreachable"
    )
    expect(!window.isVisible, "The scroll fixture became visible")
    print("NATIVE_SCROLL_CHECK_PASS")
  }

  private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fail(message) }
  }

  private static func expect<Value>(_ value: Value?, _ message: String) -> Value {
    guard let value else { fail(message) }
    return value
  }

  private static func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("NATIVE_SCROLL_CHECK_FAIL: \(message)\n".utf8))
    exit(EXIT_FAILURE)
  }

  @MainActor
  private static func descendants(of view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap { descendants(of: $0) }
  }
}
