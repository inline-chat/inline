import UIKit

/// Moves the flight from where the composer's text was to where its bubble lands, as Telegram's send
/// transition does: the view sits at its landing frame and additive position tracks carry it there,
/// sideways on the horizontal curve and up on the vertical one. A retarget adds another pair of tracks
/// for the difference, so a second send or a list change mid-flight continues from what is on screen
/// at the same velocity.
@MainActor
final class SendMessageAnimationFrameAnimator {
  private weak var view: UIView?
  private let fromFrame: CGRect
  private var toFrame: CGRect
  private let initialDuration: TimeInterval
  private let completion: (UIViewAnimatingPosition) -> Void
  private var generation = 0
  private var isRunning = false

  init(
    view: UIView,
    from fromFrame: CGRect,
    to toFrame: CGRect,
    duration: TimeInterval,
    completion: @escaping (UIViewAnimatingPosition) -> Void = { _ in }
  ) {
    self.view = view
    self.fromFrame = fromFrame
    self.toFrame = toFrame
    initialDuration = duration
    self.completion = completion
  }

  func start() {
    guard !isRunning else { return }
    guard let view else {
      completion(.current)
      return
    }
    view.transform = .identity
    view.frame = toFrame
    guard initialDuration > 0 else {
      completion(.end)
      return
    }
    isRunning = true
    addTracks(
      dx: fromFrame.midX - toFrame.midX, dy: fromFrame.midY - toFrame.midY, duration: initialDuration
    )
  }

  func retarget(to newTargetFrame: CGRect, duration: TimeInterval) -> CGRect? {
    guard let view, isRunning else {
      completion(.current)
      return nil
    }
    let presentationFrame = view.layer.presentation()?.frame ?? view.frame
    let dx = toFrame.midX - newTargetFrame.midX
    let dy = toFrame.midY - newTargetFrame.midY
    toFrame = newTargetFrame
    view.frame = newTargetFrame
    guard duration > 0 else {
      view.layer.removeAllAnimations()
      isRunning = false
      completion(.end)
      return presentationFrame
    }
    addTracks(dx: dx, dy: dy, duration: duration)
    return presentationFrame
  }

  func stop() {
    isRunning = false
    generation += 1
  }

  /// Completes when the newest pair ends: earlier pairs end sooner, and their difference is already in
  /// the newer one's target.
  private func addTracks(dx: CGFloat, dy: CGFloat, duration: TimeInterval) {
    guard let layer = view?.layer else { return }
    generation += 1
    let current = generation
    CATransaction.begin()
    CATransaction.setCompletionBlock { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.isRunning, self.generation == current else { return }
        self.isRunning = false
        self.completion(.end)
      }
    }
    Self.addTrack(layer, "position.x", dx, duration, SendMessageAnimationTiming.horizontalMediaTimingFunction)
    Self.addTrack(layer, "position.y", dy, duration, SendMessageAnimationTiming.verticalMediaTimingFunction)
    CATransaction.commit()
  }

  private static func addTrack(
    _ layer: CALayer, _ keyPath: String, _ delta: CGFloat, _ duration: TimeInterval, _ timing: CAMediaTimingFunction
  ) {
    let track = CABasicAnimation(keyPath: keyPath)
    track.fromValue = delta
    track.toValue = 0
    track.isAdditive = true
    track.duration = duration
    track.timingFunction = timing
    track.fillMode = .backwards
    // A zero distance still runs, so the pair's completion fires on time.
    layer.add(track, forKey: nil)
  }

  static func sourceTransform(from sourceFrame: CGRect, to targetFrame: CGRect) -> CGAffineTransform {
    CGAffineTransform(
      translationX: sourceFrame.midX - targetFrame.midX,
      y: sourceFrame.midY - targetFrame.midY
    )
  }
}
