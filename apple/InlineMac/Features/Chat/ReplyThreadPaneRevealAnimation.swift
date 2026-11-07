import AppKit
import QuartzCore

/// Drives the side pane's revealed fraction once per display frame.
///
/// SwiftUI does not reliably interpolate the frames of hosted AppKit chat views,
/// so the reveal is stepped explicitly. Each frame lays out like a divider drag:
/// the pane keeps its target width and is clipped, and only the primary chat reflows.
@MainActor
@Observable
final class ReplyThreadPaneRevealAnimation {
  static let openDuration: CFTimeInterval = 0.22
  static let closeDuration: CFTimeInterval = 0.18

  private(set) var progress: CGFloat = 0
  private(set) var isAnimating = false

  @ObservationIgnored private var startProgress: CGFloat = 0
  @ObservationIgnored private var targetProgress: CGFloat = 0
  @ObservationIgnored private var startTime: CFTimeInterval = 0
  @ObservationIgnored private var duration: CFTimeInterval = 0
  @ObservationIgnored private var completion: (() -> Void)?
  @ObservationIgnored private var displayLink: CADisplayLink?
  @ObservationIgnored private lazy var displayLinkTarget = DisplayLinkTarget { [weak self] in
    guard let self else { return false }
    step()
    return true
  }

  /// Animates from the current in-flight progress, or from the opposite end when idle.
  func animate(to target: CGFloat, in window: NSWindow?, completion: @escaping () -> Void) {
    let from = isAnimating ? progress : (target > 0.5 ? 0 : 1)
    self.completion = nil
    stopDisplayLink()

    let screen = window?.screen ?? NSScreen.main
    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
          let screen,
          abs(target - from) > 0.001
    else {
      progress = target
      isAnimating = false
      completion()
      return
    }

    startProgress = from
    targetProgress = target
    duration = (target > from ? Self.openDuration : Self.closeDuration) * Double(abs(target - from))
    startTime = CACurrentMediaTime()
    self.completion = completion
    progress = from
    isAnimating = true

    let link = screen.displayLink(target: displayLinkTarget, selector: #selector(DisplayLinkTarget.tick(_:)))
    link.add(to: .main, forMode: .common)
    displayLink = link
  }

  /// Jumps to a resting state without running the pending completion.
  func reset(to target: CGFloat) {
    completion = nil
    stopDisplayLink()
    progress = target
    isAnimating = false
  }

  private func step() {
    guard isAnimating else {
      stopDisplayLink()
      return
    }

    let elapsed = CACurrentMediaTime() - startTime
    let t = duration > 0 ? min(1, max(0, elapsed / duration)) : 1
    let eased = targetProgress > startProgress ? Self.easeOutCubic(t) : Self.easeInOutCubic(t)
    progress = startProgress + (targetProgress - startProgress) * eased

    guard t >= 1 else { return }
    progress = targetProgress
    isAnimating = false
    stopDisplayLink()
    let completion = completion
    self.completion = nil
    completion?()
  }

  private func stopDisplayLink() {
    displayLink?.invalidate()
    displayLink = nil
  }

  private static func easeOutCubic(_ t: Double) -> Double {
    1 - pow(1 - t, 3)
  }

  private static func easeInOutCubic(_ t: Double) -> Double {
    t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
  }
}

private final class DisplayLinkTarget: NSObject {
  /// Returns false once the owner is gone, so an orphaned link stops itself.
  private let onTick: @MainActor () -> Bool

  init(onTick: @escaping @MainActor () -> Bool) {
    self.onTick = onTick
  }

  @MainActor @objc func tick(_ link: CADisplayLink) {
    if !onTick() {
      link.invalidate()
    }
  }
}
