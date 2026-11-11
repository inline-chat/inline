import Intents
import InlineKit

/// The system launches this extension when the user's Focus starts or ends, if
/// Inline may read Focus. It forwards the change so DM partners see it while the
/// app is closed.
final class IntentHandler: INExtension, INShareFocusStatusIntentHandling {
  override func handler(for intent: INIntent) -> Any {
    self
  }

  func handle(intent: INShareFocusStatusIntent) async -> INShareFocusStatusIntentResponse {
    if let focused = intent.focusStatus?.isFocused {
      await FocusStatusDirectReport.send(focused: focused)
    }
    return INShareFocusStatusIntentResponse(code: .success, userActivity: nil)
  }
}
