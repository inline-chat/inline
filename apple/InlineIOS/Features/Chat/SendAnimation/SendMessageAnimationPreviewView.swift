import UIKit

@MainActor
final class SendMessageAnimationPreviewView: UIView {
  private let source: SendMessageAnimationSource
  private let preparedAt: Date
  private var targetBubbleSnapshotView: UIView?
  private var activeMovementAnimator: SendMessageAnimationFrameAnimator?
  private var currentTargetFrame: CGRect?
  private var completionHandler: (() -> Void)?

  init(source: SendMessageAnimationSource) {
    self.source = source
    preparedAt = source.preparedAt

    super.init(frame: .zero)

    isUserInteractionEnabled = false
    backgroundColor = .clear
    isOpaque = false
    clipsToBounds = false
    layer.zPosition = 10_000
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func animate(
    to target: SendMessageAnimationTarget,
    in containerView: UIView,
    completion: @escaping () -> Void
  ) {
    activeMovementAnimator?.stop()
    activeMovementAnimator = nil
    targetBubbleSnapshotView?.removeFromSuperview()
    targetBubbleSnapshotView = nil
    currentTargetFrame = nil
    completionHandler = completion

    guard let window = containerView.window else {
      SendMessageAnimationDiagnostics.event("preview animate-abort missing-window")
      completion()
      removeFromSuperview()
      return
    }

    let overlayContainer = window
    let targetFrame = target.bubbleFrameInWindow
    let sourceTextFrame = source.sourceVisibleTextFrameInWindow
    let sourceBaselineY = source.sourceTextFirstBaselineYInWindow
    let startResolution = SendMessageAnimationStartFrameResolver.resolve(
      source: source,
      target: target
    )
    let startFrame = startResolution.frame

    guard targetFrame.isFiniteAndVisible,
          sourceTextFrame.isFiniteAndVisible,
          startFrame.isFiniteAndVisible,
          sourceBaselineY.isFinite
    else {
      SendMessageAnimationDiagnostics.event(
        "preview animate-abort invalid-frames start=[\(SendMessageAnimationDiagnostics.rect(startFrame))] target=[\(SendMessageAnimationDiagnostics.rect(targetFrame))] sourceText=[\(SendMessageAnimationDiagnostics.rect(sourceTextFrame))] sourceBaselineY=\(String(format: "%.1f", sourceBaselineY))"
      )
      completion()
      removeFromSuperview()
      return
    }

    let snapshotView = target.bubbleSnapshotView
    Self.configureOverlaySnapshot(snapshotView)
    snapshotView.frame = boundsForSnapshot(size: targetFrame.size)
    snapshotView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    targetBubbleSnapshotView = snapshotView
    currentTargetFrame = targetFrame

    frame = targetFrame
    addSubview(snapshotView)
    overlayContainer.addSubview(self)
    overlayContainer.bringSubviewToFront(self)

    let movementDuration = SendMessageAnimationTiming.retargetDuration(
      preparedAt: preparedAt
    )
    let targetTextStartFrame = CGRect(
      x: startFrame.minX + target.textFrameInBubble.minX,
      y: startFrame.minY + target.textFrameInBubble.minY,
      width: target.textFrameInBubble.width,
      height: target.textFrameInBubble.height
    )
    let targetBaselineStartY = startFrame.minY + target.textFirstBaselineYInBubble
    let targetAnchorStartY = startFrame.minY + startResolution.targetAnchorYInBubble
    let targetTextEndFrame = target.textFrameInWindow
    let sourceTransform = SendMessageAnimationFrameAnimator.sourceTransform(
      from: startFrame,
      to: targetFrame
    )
    let elapsedMs = Date().timeIntervalSince(preparedAt) * 1_000

    SendMessageAnimationDiagnostics.debug(
      "preview animate-start mode=real-target-bubble overlay=window motion=transform motionTx=\(String(format: "%.1f", sourceTransform.tx)) motionTy=\(String(format: "%.1f", sourceTransform.ty)) from=[\(SendMessageAnimationDiagnostics.rect(startFrame))] to=[\(SendMessageAnimationDiagnostics.rect(targetFrame))] sourceText=[\(SendMessageAnimationDiagnostics.rect(sourceTextFrame))] sourceBaselineY=\(String(format: "%.1f", sourceBaselineY)) sourceAnchorY=\(String(format: "%.1f", startResolution.sourceAnchorY)) sourceLineHeight=\(String(format: "%.1f", source.sourceLineHeight)) anchorProgress=\(String(format: "%.2f", startResolution.verticalAnchorProgress)) targetTextStart=[\(SendMessageAnimationDiagnostics.rect(targetTextStartFrame))] targetTextEnd=[\(SendMessageAnimationDiagnostics.rect(targetTextEndFrame))] targetTextStartDelta=[\(Self.rectDelta(from: sourceTextFrame, to: targetTextStartFrame))] baselineStartDelta=\(String(format: "%.1f", targetBaselineStartY - sourceBaselineY)) anchorStartDelta=\(String(format: "%.1f", targetAnchorStartY - startResolution.sourceAnchorY)) targetTextInBubble=[\(SendMessageAnimationDiagnostics.rect(target.textFrameInBubble))] targetBaselineInBubble=\(String(format: "%.1f", target.textFirstBaselineYInBubble)) targetSnapshot=\(type(of: snapshotView)) duration=\(String(format: "%.3f", movementDuration)) elapsedSincePrepareMs=\(String(format: "%.1f", elapsedMs)) animationsEnabled=\(UIView.areAnimationsEnabled) inheritedDuration=\(String(format: "%.3f", UIView.inheritedAnimationDuration))"
    )

    let animator = SendMessageAnimationFrameAnimator(
      view: self,
      from: startFrame,
      to: targetFrame,
      duration: movementDuration,
      completion: { [weak self] position in
        self?.finishAnimation(position: position)
      }
    )
    activeMovementAnimator = animator
    animator.start()
  }

  @discardableResult
  func retarget(
    to target: SendMessageAnimationTarget,
    duration: TimeInterval
  ) -> Bool {
    guard let activeMovementAnimator,
          superview != nil
    else {
      SendMessageAnimationDiagnostics.event(
        "preview retarget-abort missing-active-view stable=\(target.messageStableId) random=\(target.identity.randomId)"
      )
      return false
    }

    let previousTargetFrame = currentTargetFrame ?? frame
    let newTargetFrame = target.bubbleFrameInWindow
    guard newTargetFrame.isFiniteAndVisible else {
      SendMessageAnimationDiagnostics.event(
        "preview retarget-abort invalid-target stable=\(target.messageStableId) random=\(target.identity.randomId) target=[\(SendMessageAnimationDiagnostics.rect(newTargetFrame))]"
      )
      return false
    }

    currentTargetFrame = newTargetFrame
    let presentationFrame = activeMovementAnimator.retarget(
      to: newTargetFrame,
      duration: duration
    ) ?? frame

    SendMessageAnimationDiagnostics.debug(
      "preview retarget-start stable=\(target.messageStableId) random=\(target.identity.randomId) presentation=[\(SendMessageAnimationDiagnostics.rect(presentationFrame))] previousTarget=[\(SendMessageAnimationDiagnostics.rect(previousTargetFrame))] newTarget=[\(SendMessageAnimationDiagnostics.rect(newTargetFrame))] delta=[\(Self.rectDelta(from: previousTargetFrame, to: newTargetFrame))] duration=\(String(format: "%.3f", duration))"
    )
    return true
  }

  func cancel() {
    activeMovementAnimator?.stop()
    activeMovementAnimator = nil
    targetBubbleSnapshotView = nil
    currentTargetFrame = nil
    completionHandler = nil
    removeFromSuperview()
  }

  private func boundsForSnapshot(size: CGSize) -> CGRect {
    CGRect(origin: .zero, size: size)
  }

  private static func configureOverlaySnapshot(_ snapshotView: UIView) {
    snapshotView.layer.removeAllAnimations()
    snapshotView.alpha = 1
    snapshotView.transform = .identity
    snapshotView.backgroundColor = .clear
    snapshotView.isOpaque = false
    snapshotView.clipsToBounds = false
    snapshotView.isUserInteractionEnabled = false
  }

  private func finishAnimation(position: UIViewAnimatingPosition) {
    let finishedAtTarget = position == .end
    let targetFrame = currentTargetFrame ?? frame
    SendMessageAnimationDiagnostics.event(
      "preview animate-finish position=\(Self.description(for: position)) finishedAtTarget=\(finishedAtTarget) frame=[\(SendMessageAnimationDiagnostics.rect(frame))] target=[\(SendMessageAnimationDiagnostics.rect(targetFrame))]"
    )
    let completion = completionHandler
    completionHandler = nil
    targetBubbleSnapshotView = nil
    currentTargetFrame = nil
    activeMovementAnimator = nil
    removeFromSuperview()
    completion?()
  }

  private static func rectDelta(from: CGRect, to: CGRect) -> String {
    "dx=\(String(format: "%.1f", to.minX - from.minX)) dy=\(String(format: "%.1f", to.minY - from.minY)) dw=\(String(format: "%.1f", to.width - from.width)) dh=\(String(format: "%.1f", to.height - from.height))"
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
