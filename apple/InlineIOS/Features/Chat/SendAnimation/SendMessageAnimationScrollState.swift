import UIKit

struct SendMessageAnimationScrollPlan {
  let targetOffset: CGPoint
  let modelContentOffsetYDeltaToTarget: CGFloat
  let presentationContentOffsetYDeltaToTarget: CGFloat?
}

@MainActor
final class SendMessageAnimationScrollState {
  private var composeInsetAnimator: UIViewPropertyAnimator?
  private var composeInsetCompletion: (() -> Void)?
  private var scrollAnimator: UIViewPropertyAnimator?
  private var scrollCompletion: (() -> Void)?
  private var scrollTargetOffset: CGPoint?

  var isScrollInFlight: Bool {
    scrollAnimator != nil
  }

  func startComposeInsetAnimation(
    to targetOffset: CGPoint,
    duration: TimeInterval = SendMessageAnimationTiming.duration,
    timingParameters: UITimingCurveProvider? = SendMessageAnimationTiming.verticalTimingParameters,
    in collectionView: UICollectionView,
    completion: (() -> Void)? = nil
  ) {
    if composeInsetAnimator != nil {
      stopComposeInsetAnimationAtPresentation(in: collectionView)
    }

    let animator: UIViewPropertyAnimator
    if let timingParameters {
      animator = UIViewPropertyAnimator(duration: duration, timingParameters: timingParameters)
    } else {
      animator = UIViewPropertyAnimator(duration: duration, curve: .easeInOut)
    }
    composeInsetAnimator = animator
    composeInsetCompletion = completion
    animator.addAnimations { [weak collectionView] in
      guard let collectionView else { return }
      collectionView.setContentOffset(targetOffset, animated: false)
      collectionView.layoutIfNeeded()
    }
    animator.addCompletion { [weak self] _ in
      guard let self, self.composeInsetAnimator === animator else { return }
      self.composeInsetAnimator = nil
      let completion = self.composeInsetCompletion
      self.composeInsetCompletion = nil
      completion?()
    }
    animator.startAnimation()
  }

  @discardableResult
  func stopComposeInsetAnimationAtPresentation(
    in collectionView: UICollectionView
  ) -> Bool {
    guard composeInsetAnimator != nil else { return false }

    let presentationOffsetY = collectionView.layer.presentation()?.bounds.origin.y
    composeInsetAnimator?.stopAnimation(true)
    composeInsetAnimator = nil
    let completion = composeInsetCompletion
    composeInsetCompletion = nil

    if let presentationOffsetY, presentationOffsetY.isFinite {
      collectionView.setContentOffset(
        CGPoint(x: collectionView.contentOffset.x, y: presentationOffsetY),
        animated: false
      )
      collectionView.layoutIfNeeded()
    }
    completion?()
    return true
  }

  func cancel(in collectionView: UICollectionView) {
    stopComposeInsetAnimationAtPresentation(in: collectionView)
    stopScrollAtPresentation(in: collectionView)
  }

  func activeScrollPlanToTarget(
    in collectionView: UICollectionView
  ) -> SendMessageAnimationScrollPlan? {
    guard let scrollTargetOffset else { return nil }
    let currentOffsetY = collectionView.layer.presentation()?.bounds.origin.y
      ?? collectionView.contentOffset.y
    guard currentOffsetY.isFinite else { return nil }

    let targetOffset = clampedContentOffset(scrollTargetOffset, in: collectionView)
    let modelContentOffsetYDeltaToTarget = targetOffset.y - collectionView.contentOffset.y
    let presentationContentOffsetYDeltaToTarget = targetOffset.y - currentOffsetY
    guard abs(modelContentOffsetYDeltaToTarget) > 0.5 ||
      abs(presentationContentOffsetYDeltaToTarget) > 0.5
    else {
      return nil
    }

    return SendMessageAnimationScrollPlan(
      targetOffset: targetOffset,
      modelContentOffsetYDeltaToTarget: modelContentOffsetYDeltaToTarget,
      presentationContentOffsetYDeltaToTarget: presentationContentOffsetYDeltaToTarget
    )
  }

  func clampedContentOffset(
    _ offset: CGPoint,
    in collectionView: UICollectionView
  ) -> CGPoint {
    let minX = -collectionView.contentInset.left
    let maxX = max(
      minX,
      collectionView.contentSize.width - collectionView.bounds.width + collectionView.contentInset.right
    )
    let minY = -collectionView.contentInset.top
    let maxY = max(
      minY,
      collectionView.contentSize.height - collectionView.bounds.height + collectionView.contentInset.bottom
    )

    return CGPoint(
      x: min(max(offset.x, minX), maxX),
      y: min(max(offset.y, minY), maxY)
    )
  }

  func animateScroll(
    to targetOffset: CGPoint,
    duration: TimeInterval,
    in collectionView: UICollectionView,
    completion: (() -> Void)? = nil
  ) {
    stopComposeInsetAnimationAtPresentation(in: collectionView)

    if scrollAnimator != nil {
      stopScrollAtPresentation(in: collectionView)
    }

    let startedAt = CACurrentMediaTime()
    let animator = SendMessageAnimationTiming.makeVerticalAnimator(duration: duration)
    scrollAnimator = animator
    scrollCompletion = completion
    let clampedTargetOffset = clampedContentOffset(targetOffset, in: collectionView)
    scrollTargetOffset = clampedTargetOffset
    SendMessageAnimationDiagnostics.event(
      "list scroll-start fromY=\(String(format: "%.1f", collectionView.contentOffset.y)) toY=\(String(format: "%.1f", clampedTargetOffset.y)) duration=\(String(format: "%.3f", duration))"
    )
    animator.addAnimations { [weak collectionView] in
      guard let collectionView else { return }
      collectionView.setContentOffset(clampedTargetOffset, animated: false)
      collectionView.layoutIfNeeded()
    }
    animator.addCompletion { [weak self, weak collectionView] position in
      guard let self, self.scrollAnimator === animator else { return }
      self.scrollAnimator = nil
      self.scrollTargetOffset = nil
      let completion = self.scrollCompletion
      self.scrollCompletion = nil
      let elapsedMs = (CACurrentMediaTime() - startedAt) * 1_000
      SendMessageAnimationDiagnostics.event(
        "list scroll-finish elapsedMs=\(String(format: "%.1f", elapsedMs)) position=\(Self.description(for: position)) finalY=\(String(format: "%.1f", collectionView?.contentOffset.y ?? 0))"
      )
      completion?()
    }
    animator.startAnimation()
  }

  private func stopScrollAtPresentation(in collectionView: UICollectionView) {
    guard scrollAnimator != nil else {
      scrollTargetOffset = nil
      let completion = scrollCompletion
      scrollCompletion = nil
      completion?()
      return
    }

    let presentationOffsetY = collectionView.layer.presentation()?.bounds.origin.y
    scrollAnimator?.stopAnimation(true)
    scrollAnimator = nil
    scrollTargetOffset = nil
    let completion = scrollCompletion
    scrollCompletion = nil

    if let presentationOffsetY, presentationOffsetY.isFinite {
      collectionView.layer.removeAnimation(forKey: "bounds")
      collectionView.setContentOffset(
        CGPoint(x: collectionView.contentOffset.x, y: presentationOffsetY),
        animated: false
      )
      collectionView.layoutIfNeeded()
    }
    completion?()
  }

  private static func description(for position: UIViewAnimatingPosition) -> String {
    switch position {
    case .start:
      "start"
    case .end:
      "end"
    case .current:
      "current"
    @unknown default:
      "unknown"
    }
  }
}
