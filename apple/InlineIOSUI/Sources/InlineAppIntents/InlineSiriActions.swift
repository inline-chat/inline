#if compiler(>=6.4)
import AppIntents
import Auth
import Foundation
import GeoToolbox
import InlineKit
import InlineProtocol

@available(iOS 27.0, macOS 27.0, *)
public typealias InlineSiriRecipients = [InlineSiriPersonEntity]

@available(iOS 27.0, macOS 27.0, *)
@UnionValue
public enum InlineSiriDestination: Sendable {
  case person(InlineSiriPersonEntity)
  case recipients(InlineSiriRecipients)

  func resolve(account: AuthAccountMutationToken) async throws -> InlineIntentChat {
    switch self {
    case let .recipients(values):
      guard values.count == 1, let person = values.first else { throw InlineIntentError.unsupportedContent }
      return try await Self.person(person).resolve(account: account)
    case let .person(value):
      guard let userID = value.userID(for: account.userID) else { throw InlineIntentError.unavailable }
      return try await InlineIntentMessaging.connected(account: account) { realtime in
        let inbox = try await InlineIntentMessaging.inbox(on: realtime, account: account)
        return try await InlineIntentMessaging.directConversation(
          userID: userID,
          on: realtime,
          inbox: inbox,
          account: account
        ).conversation.chat
      }
    }
  }
}

@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .messages.sendMessage)
public struct SendInlineMessageAIIntent {
  public static var allowedExecutionTargets: IntentExecutionTargets { .main }
  public static let isAssistantOnly = true
  public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
  public var destination: InlineSiriDestination
  public var subject: AttributedString?
  public var content: AttributedString?
  public var attachments: [IntentFile]
  public var audioMessage: IntentFile?
  public var locations: [PlaceDescriptor]
  public var links: [URL]
  public var scheduledDate: Date?
  public init() {}

  public func perform() async throws -> some ReturnsValue<[InlineSiriMessageEntity]> {
    guard subject == nil, attachments.isEmpty, audioMessage == nil, locations.isEmpty, scheduledDate == nil else {
      throw InlineIntentError.unsupportedContent
    }
    let text = ([content.map { String($0.characters) } ?? ""] + links.map(\.absoluteString)).filter { !$0.isEmpty }.joined(separator: "\n")
    try InlineIntentService.validateMessage(text)
    let account = try await InlineIntentService.account()
    let person: InlineSiriPersonEntity
    switch destination {
    case let .person(value): person = value
    case let .recipients(values):
      guard values.count == 1, let value = values.first else { throw InlineIntentError.unsupportedContent }
      person = value
    }
    guard let userID = person.userID(for: account.userID) else { throw InlineIntentError.unavailable }
    let verifiedPerson = try await person.verified(account: account)
    try InlineIntentService.validate(account)
    // Creating the DM is a server mutation. Keep it after confirmation with the send itself.
    try await requestConfirmation(
      actionName: .send,
      dialog: InlineIntentDialogs.confirmSend(toPersonNamed: verifiedPerson.confirmationName)
    )
    let sent = try await InlineIntentMessaging.send(text: text, userID: userID, account: account)
    return .result(value: sent.map(InlineSiriMessageEntity.init))
  }
}

@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .messages.draftMessage)
public struct DraftInlineMessageAIIntent {
  public static var allowedExecutionTargets: IntentExecutionTargets { .main }
  public static let isAssistantOnly = true
  public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
  public static var supportedModes: IntentModes { .foreground }
  public var destination: InlineSiriDestination?
  public var subject: AttributedString?
  public var content: AttributedString?
  public var attachments: [IntentFile]
  public var audioMessage: IntentFile?
  public var locations: [PlaceDescriptor]
  public var links: [URL]
  public var scheduledDate: Date?
  @Dependency(default: { () async throws -> InlineIntentDraftNavigation in throw InlineIntentError.appNotReady })
  private var navigation: InlineIntentDraftNavigation
  public init() {}

  public func perform() async throws -> some IntentResult {
    guard subject == nil, attachments.isEmpty, audioMessage == nil, locations.isEmpty, scheduledDate == nil else {
      throw InlineIntentError.unsupportedContent
    }
    guard let destination else { throw InlineIntentError.unsupportedContent }
    let account = try await InlineIntentService.account()
    try await requestConfirmation(dialog: InlineIntentDialogs.confirmDraft)
    try InlineIntentService.validate(account)
    let target = try await destination.resolve(account: account)
    let text = ([content.map { String($0.characters) } ?? ""] + links.map(\.absoluteString)).filter { !$0.isEmpty }.joined(separator: "\n")
    try InlineIntentService.validate(account)
    try await navigation.compose(target.peer, account, text)
    return .result()
  }
}

@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .messages.editSentMessage)
public struct EditInlineMessageAIIntent {
  public static var allowedExecutionTargets: IntentExecutionTargets { .main }
  public static let isAssistantOnly = true
  public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
  public var message: InlineSiriMessageEntity
  public var content: AttributedString
  public init() {}
  public func perform() async throws -> some IntentResult {
    let account = try await InlineIntentService.account()
    let text = String(content.characters)
    try InlineIntentService.validateMessage(text)
    let target = try await InlineIntentMessaging.ownedMessage(message.id, account: account)
    try await requestConfirmation(dialog: InlineIntentDialogs.confirmEdit(in: target.conversation.chat))
    try await InlineIntentMessaging.mutate(target.id.rawValue, operation: .edit(text), account: account)
    return .result()
  }
}

@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .messages.unsendMessage)
public struct UnsendInlineMessageAIIntent {
  public static var allowedExecutionTargets: IntentExecutionTargets { .main }
  public static let isAssistantOnly = true
  public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
  public var message: InlineSiriMessageEntity
  public init() {}
  public func perform() async throws -> some IntentResult {
    let account = try await InlineIntentService.account()
    let target = try await InlineIntentMessaging.ownedMessage(message.id, account: account)
    try await requestConfirmation(dialog: "Unsend your message in \(target.conversation.chat.title)?")
    try await InlineIntentMessaging.mutate(target.id.rawValue, operation: .unsend, account: account)
    return .result()
  }
}

@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .messages.setMessageReadStatus)
public struct SetInlineMessageReadAIIntent {
  public static var allowedExecutionTargets: IntentExecutionTargets { .main }
  public static let isAssistantOnly = true
  public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
  public var message: InlineSiriMessageEntity
  public var isRead: Bool
  public init() {}
  public func perform() async throws -> some IntentResult {
    let account = try await InlineIntentService.account()
    try await InlineIntentMessaging.mutate(message.id, operation: isRead ? .read : .unread, account: account)
    return .result()
  }
}
#endif
