import UIKit

@MainActor
extension ComposeView {
  func makeTextSendAnimationSource(
    identity: SendMessageAnimationIdentity,
    text: String
  ) -> SendMessageAnimationSource? {
    guard sendAnimationCoordinator?.canPrepareTextSendSource() != false else {
      SendMessageAnimationDiagnostics.event(
        "source unavailable-list-not-bottom random=\(identity.randomId)"
      )
      return nil
    }

    return SendMessageAnimationSourceCapture.capture(
      identity: identity,
      text: text,
      textView: textView,
      composeHeight: composeHeightConstraint.constant
    )
  }
}
