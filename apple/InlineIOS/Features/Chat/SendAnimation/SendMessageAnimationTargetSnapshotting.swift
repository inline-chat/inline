import UIKit

@MainActor
enum SendMessageAnimationTargetSnapshotting {
  static func makeSnapshot(
    from bubbleView: MessageBubbleView,
    side: MessageBubbleTailSide
  ) -> UIView? {
    bubbleView.layoutIfNeeded()
    bubbleView.contentView.layoutIfNeeded()
    removeLayerAnimations(from: bubbleView)

    guard bubbleView.bounds.isFiniteAndVisible,
          bubbleView.contentView.bounds.isFiniteAndVisible
    else {
      SendMessageAnimationDiagnostics.event(
        "target snapshot-unavailable invalid-bounds bubble=[\(SendMessageAnimationDiagnostics.rect(bubbleView.bounds))] content=[\(SendMessageAnimationDiagnostics.rect(bubbleView.contentView.bounds))]"
      )
      return nil
    }

    let previousContentAlpha = bubbleView.contentView.alpha
    let previousContentHidden = bubbleView.contentView.isHidden
    if previousContentHidden || previousContentAlpha <= 0.001 {
      SendMessageAnimationDiagnostics.debug(
        "target snapshot-content-view-temporarily-visible alpha=\(String(format: "%.2f", previousContentAlpha)) hidden=\(previousContentHidden)"
      )
    }
    SendMessageAnimationActions.performWithoutAnimation {
      bubbleView.contentView.alpha = 1
      bubbleView.contentView.isHidden = false
      bubbleView.contentView.layoutIfNeeded()
      removeLayerAnimations(from: bubbleView)
    }
    defer {
      SendMessageAnimationActions.performWithoutAnimation {
        bubbleView.contentView.alpha = previousContentAlpha
        bubbleView.contentView.isHidden = previousContentHidden
        bubbleView.contentView.layoutIfNeeded()
      }
    }

    guard let snapshotView = bubbleView.sendAnimationLayerSnapshotView(
      debugName: "target-bubble-full"
    ) else {
      SendMessageAnimationDiagnostics.event(
        "target snapshot-unavailable full-bubble-snapshot bubble=[\(SendMessageAnimationDiagnostics.rect(bubbleView.bounds))] content=[\(SendMessageAnimationDiagnostics.rect(bubbleView.contentView.bounds))]"
      )
      return nil
    }

    let alphaSample = (snapshotView as? UIImageView)?
      .image?
      .sendAnimationVisibleAlphaSample()
    if let alphaSample,
       alphaSample.visible == 0 {
      SendMessageAnimationDiagnostics.event(
        "target snapshot-unavailable blank-full-bubble alphaPct=\(String(format: "%.1f", alphaSample.coverage * 100)) visible=\(alphaSample.visible)/\(alphaSample.total)"
      )
      return nil
    }

    snapshotView.frame = CGRect(origin: .zero, size: bubbleView.bounds.size)
    snapshotView.backgroundColor = .clear
    snapshotView.isOpaque = false
    snapshotView.clipsToBounds = false
    snapshotView.isUserInteractionEnabled = false
    removeLayerAnimations(from: snapshotView)

    SendMessageAnimationDiagnostics.debug(
      "target snapshot-full-bubble side=\(side) bubble=[\(SendMessageAnimationDiagnostics.rect(bubbleView.bounds))] content=[\(SendMessageAnimationDiagnostics.rect(bubbleView.contentView.frame))] snapshot=\(type(of: snapshotView)) alphaPct=\(alphaSample.map { String(format: "%.1f", $0.coverage * 100) } ?? "nil") visible=\(alphaSample.map { "\($0.visible)/\($0.total)" } ?? "nil")"
    )
    return snapshotView
  }

  private static func removeLayerAnimations(from view: UIView) {
    view.layer.removeAllAnimations()
    view.subviews.forEach { removeLayerAnimations(from: $0) }
  }
}
