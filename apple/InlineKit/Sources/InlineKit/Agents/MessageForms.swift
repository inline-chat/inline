import Foundation
import InlineProtocol

/// One answer in a bot form (`BlockForm`), as the viewer is editing it.
public enum MessageFormDraftValue: Equatable, Sendable {
  case text(String)
  case selection([String], other: String?)
  case toggle(Bool)
  case number(Double)
}

/// In-memory answers for open forms, so scrolling, streaming edits and view
/// reuse never lose what the viewer typed. Nothing here is persisted: secret
/// answers live only until submit or until the app quits.
@MainActor
public final class MessageFormDraftStore {
  public static let shared = MessageFormDraftStore()

  public struct Key: Hashable, Sendable {
    public let message: BlockContentMessageIdentity
    public let formID: String

    public init(message: Message, formID: String) {
      self.message = BlockContentMessageIdentity(message: message)
      self.formID = formID
    }
  }

  public enum Phase: Equatable, Sendable {
    case editing
    case submitting
    case submitted
  }

  private var drafts: [Key: [String: MessageFormDraftValue]] = [:]
  private var phases: [Key: Phase] = [:]

  public init() {}

  public func value(_ key: Key, fieldID: String) -> MessageFormDraftValue? {
    drafts[key]?[fieldID]
  }

  public func setValue(_ value: MessageFormDraftValue?, key: Key, fieldID: String) {
    drafts[key, default: [:]][fieldID] = value
  }

  public func phase(_ key: Key) -> Phase {
    phases[key] ?? .editing
  }

  public func setPhase(_ phase: Phase, key: Key) {
    phases[key] = phase
    if phase == .submitted {
      // Drop answers, secrets included, once the bot has them.
      drafts[key] = nil
    }
  }
}

public enum MessageFormSubmitter {
  /// Sends a form as one invocation (`action_id = form_id`). This is a direct
  /// RPC, never a queued or persisted transaction, because answers can hold
  /// secrets. Returns the interaction ID the bot answers with.
  @MainActor
  public static func submit(
    message: Message,
    formID: String,
    values: [(fieldID: String, value: MessageFormDraftValue)]
  ) async throws -> Int64 {
    let submission = InlineProtocol.MessageFormSubmission.with { submission in
      submission.values = values.map { entry in
        InlineProtocol.MessageFormValue.with { value in
          value.fieldID = entry.fieldID
          switch entry.value {
          case let .text(text):
            value.text = text
          case let .selection(ids, other):
            value.selection = .with {
              $0.optionIds = ids
              if let other { $0.otherText = other }
            }
          case let .toggle(isOn):
            value.toggle = isOn
          case let .number(number):
            value.number = number
          }
        }
      }
    }
    let response = try await Api.realtime.callRpcDirect(
      method: .invokeMessageAction,
      input: .invokeMessageAction(.with {
        $0.peerID = message.peerId.toInputPeer()
        $0.messageID = message.messageId
        $0.actionID = formID
        $0.form = submission
      })
    )
    guard case let .invokeMessageAction(result)? = response else {
      throw MessageFormSubmitterError.invalidResponse
    }
    return result.interactionID
  }
}

public enum MessageFormSubmitterError: Error {
  case invalidResponse
}
