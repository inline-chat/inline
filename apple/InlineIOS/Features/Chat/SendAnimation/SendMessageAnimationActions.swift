import UIKit

enum SendMessageAnimationActions {
  static func performWithoutAnimation<Result>(_ updates: () -> Result) -> Result {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    var result: Result?
    UIView.performWithoutAnimation {
      result = updates()
    }
    CATransaction.commit()
    guard let result else {
      preconditionFailure("UIView.performWithoutAnimation did not run updates")
    }
    return result
  }

  static func performWithAnimationsEnabled<Result>(
    reason: String,
    _ updates: () -> Result
  ) -> Result {
    let previousAnimationsEnabled = UIView.areAnimationsEnabled
    let previousInheritedDuration = UIView.inheritedAnimationDuration

    if !previousAnimationsEnabled {
      UIView.setAnimationsEnabled(true)
    }

    CATransaction.begin()
    CATransaction.setDisableActions(false)
    let result = updates()
    CATransaction.commit()

    if !previousAnimationsEnabled {
      UIView.setAnimationsEnabled(false)
    }

    SendMessageAnimationDiagnostics.debug(
      "animation-context reason=\(reason) previousEnabled=\(previousAnimationsEnabled) previousInheritedDuration=\(String(format: "%.3f", previousInheritedDuration)) currentEnabled=\(UIView.areAnimationsEnabled)"
    )
    return result
  }

  static func removeAnimationsRecursively(from view: UIView) {
    view.layer.removeAllAnimations()
    view.subviews.forEach { removeAnimationsRecursively(from: $0) }
  }
}
