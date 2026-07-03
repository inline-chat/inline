import UIKit

@MainActor
final class SendMessageAnimationFrameAnimator {
  private weak var view: UIView?
  private let fromFrame: CGRect
  private var toFrame: CGRect
  private let initialDuration: TimeInterval
  private let completion: (UIViewAnimatingPosition) -> Void
  private var animator: UIViewPropertyAnimator?

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
    guard animator == nil else { return }
    guard let view else {
      completion(.current)
      return
    }

    guard initialDuration > 0 else {
      view.frame = toFrame
      view.transform = .identity
      completion(.end)
      return
    }

    view.frame = toFrame
    view.transform = Self.sourceTransform(from: fromFrame, to: toFrame)

    let animator = SendMessageAnimationTiming.makeVerticalAnimator(duration: initialDuration)
    animator.addAnimations { [weak view] in
      view?.transform = .identity
    }
    animator.addCompletion { [weak self, weak view] position in
      guard let self else { return }
      if position == .end {
        view?.frame = self.toFrame
        view?.transform = .identity
      }
      self.animator = nil
      self.completion(position)
    }
    self.animator = animator
    animator.startAnimation()
  }

  func retarget(to newTargetFrame: CGRect, duration: TimeInterval) -> CGRect? {
    guard let view else {
      completion(.current)
      return nil
    }

    let presentationFrame = view.layer.presentation()?.frame ?? view.frame
    animator?.stopAnimation(true)
    animator = nil

    view.layer.removeAllAnimations()
    view.transform = .identity
    view.frame = presentationFrame
    toFrame = newTargetFrame

    guard duration > 0 else {
      view.frame = newTargetFrame
      completion(.end)
      return presentationFrame
    }

    let animator = SendMessageAnimationTiming.makeVerticalAnimator(duration: duration)
    animator.addAnimations { [weak view] in
      view?.frame = newTargetFrame
      view?.transform = .identity
    }
    animator.addCompletion { [weak self, weak view] position in
      guard let self else { return }
      if position == .end {
        view?.frame = self.toFrame
        view?.transform = .identity
      }
      self.animator = nil
      self.completion(position)
    }
    self.animator = animator
    animator.startAnimation()
    return presentationFrame
  }

  func stop() {
    animator?.stopAnimation(true)
    animator = nil
  }

  static func sourceTransform(from sourceFrame: CGRect, to targetFrame: CGRect) -> CGAffineTransform {
    CGAffineTransform(
      translationX: sourceFrame.midX - targetFrame.midX,
      y: sourceFrame.midY - targetFrame.midY
    )
  }
}
