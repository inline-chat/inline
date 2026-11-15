import InlineKit
import struct InlineProtocol.MessageAction
import UIKit

/// Runs a message action from a button anywhere in the next message view: the rows under the
/// bubble or a block's own buttons. One path for grants, confirmation, client-side intents,
/// callback invocation and the shared loading state, which buttons observe through
/// `MessageActionInteractionState`.
@MainActor
enum MessageActionInvoker {
  static func loadingKey(_ actionID: String, on message: Message) -> MessageActionInteractionState.LoadingKey {
    MessageActionInteractionState.LoadingKey(
      peerId: message.peerId,
      messageId: message.messageId,
      rev: message.rev,
      actionId: actionID
    )
  }

  static func isLoading(_ actionID: String, on message: Message) -> Bool {
    MessageActionInteractionState.shared.isLoading(key: loadingKey(actionID, on: message))
  }

  /// Confirms if the action asks to, then performs it: callbacks go to the bot, the rest run
  /// on this device.
  static func tap(_ action: MessageAction, on message: Message, from view: UIView) {
    let presentation = MessageActionPerformer.presentation(for: action, message: message)
    MessageActionPerformer.run(presentation, from: view) {
      if presentation.intent == .callback {
        invokeCallback(action, on: message)
      } else {
        MessageActionPerformer.performLocal(presentation.intent, peer: message.peerId)
      }
    }
  }

  private static func invokeCallback(_ action: MessageAction, on message: Message) {
    let actionID = action.actionID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !actionID.isEmpty else { return }
    let key = loadingKey(actionID, on: message)
    guard MessageActionInteractionState.shared.begin(key: key) else { return }
    Task {
      do {
        let result = try await Api.realtime.send(.invokeMessageAction(
          peerId: message.peerId,
          messageId: message.messageId,
          actionId: actionID
        ))
        guard case let .invokeMessageAction(response) = result else {
          throw MessageActionInvokerError.invalidResponse
        }
        await MainActor.run {
          MessageActionInteractionState.shared.attachInteractionId(response.interactionID, for: key)
        }
      } catch {
        await MainActor.run {
          MessageActionInteractionState.shared.fail(key: key)
          ToastManager.shared.showToast("Action failed", type: .error, systemImage: "exclamationmark.triangle")
        }
      }
    }
  }
}

private enum MessageActionInvokerError: Error {
  case invalidResponse
}
