import AppKit

/// A plain NSScrollView with a tall document: the reference the custom list's feel is fitted to.
@MainActor
final class NativeReference {
  let scrollView = NSScrollView()
  let document = FlippedView()
  let documentHeight: CGFloat = 20_000

  final class FlippedView: NSView {
    override var isFlipped: Bool { true }
    /// `--responsive 0` takes the scroll view off its concurrent tracking path, so events handed to
    /// `scrollWheel(with:)` one by one drive it.
    nonisolated(unsafe) static var responsive = true
    override class var isCompatibleWithResponsiveScrolling: Bool { responsive }
  }

  init(frame: NSRect) {
    scrollView.frame = frame
    scrollView.hasVerticalScroller = true
    scrollView.verticalScrollElasticity = .allowed
    scrollView.drawsBackground = true
    scrollView.backgroundColor = .textBackgroundColor
    document.frame = NSRect(x: 0, y: 0, width: frame.width, height: documentHeight)
    document.wantsLayer = true
    // Stripes so a capture shows motion.
    for i in 0 ..< Int(documentHeight / 100) {
      let stripe = NSView(frame: NSRect(x: 0, y: CGFloat(i) * 100, width: frame.width, height: 50))
      stripe.wantsLayer = true
      stripe.layer?.backgroundColor = (i % 2 == 0 ? NSColor.systemBlue : NSColor.systemGray).withAlphaComponent(0.3).cgColor
      document.addSubview(stripe)
    }
    scrollView.documentView = document
  }

  var origin: CGFloat { scrollView.contentView.bounds.origin.y }
  var maxOrigin: CGFloat { documentHeight - scrollView.contentView.bounds.height }

  func scroll(to y: CGFloat) {
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
    scrollView.reflectScrolledClipView(scrollView.contentView)
  }
}
