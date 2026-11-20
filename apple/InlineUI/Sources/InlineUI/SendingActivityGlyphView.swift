#if os(macOS)
import AppKit
import QuartzCore

/// AppKit host for `SendingActivityGlyph`, for layer-built rows like the native sidebar.
///
/// Redraws from a display link only while it's in a visible window and motion is
/// allowed. Time comes from the wall clock, like SwiftUI's `TimelineView`, so it stays
/// in phase with the SwiftUI indicators on screen.
@MainActor
public final class SendingActivityGlyphView: NSView {
  public var kind: SendingActivityGlyph.Kind? {
    didSet {
      guard kind != oldValue else { return }
      needsDisplay = true
      updateDisplayLink()
    }
  }

  public var color: NSColor = .controlAccentColor {
    didSet { needsDisplay = true }
  }

  private var displayLink: CADisplayLink?
  private var reduceMotionObserver: NSObjectProtocol?

  override public var isFlipped: Bool { true }
  override public var isOpaque: Bool { false }

  override public init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layerContentsRedrawPolicy = .onSetNeedsDisplay
    setAccessibilityElement(false)
    reduceMotionObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.needsDisplay = true
        self?.updateDisplayLink()
      }
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  isolated deinit {
    displayLink?.invalidate()
    if let reduceMotionObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(reduceMotionObserver)
    }
  }

  override public func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateDisplayLink()
  }

  override public func viewDidHide() {
    super.viewDidHide()
    updateDisplayLink()
  }

  override public func viewDidUnhide() {
    super.viewDidUnhide()
    updateDisplayLink()
  }

  override public func draw(_: NSRect) {
    guard let kind, let context = NSGraphicsContext.current?.cgContext else { return }
    let time = Self.reduceMotion
      ? SendingActivityGlyph.restingTime(for: kind)
      : Date().timeIntervalSinceReferenceDate
    SendingActivityGlyph.draw(kind, in: context, rect: bounds, time: time, color: color.cgColor)
  }

  override public func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  private static var reduceMotion: Bool {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  private func updateDisplayLink() {
    let shouldRun = kind != nil && window != nil && !isHiddenOrHasHiddenAncestor && !Self.reduceMotion
    if shouldRun, displayLink == nil {
      let link = displayLink(target: self, selector: #selector(step))
      link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
      link.add(to: .main, forMode: .common)
      displayLink = link
    } else if !shouldRun, let link = displayLink {
      link.invalidate()
      displayLink = nil
    }
  }

  @objc private func step(_: CADisplayLink) {
    // Skip work for windows that are fully covered or minimized.
    guard window?.occlusionState.contains(.visible) == true else { return }
    needsDisplay = true
  }
}
#endif
