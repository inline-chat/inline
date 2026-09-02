#if compiler(>=6.4)
import AppIntents
import Foundation

// These explicit Shortcuts actions return Apple's message/conversation shapes so a user-built
// workflow can pass results into later actions. They do not make unindexed message bodies
// semantically searchable by Siri; Inline deliberately adds no second Spotlight sync owner here.
@available(iOS 27.0, macOS 27.0, *)
public struct FindUnreadInlineConversationsAIIntent: AppIntent {
  public static var allowedExecutionTargets: IntentExecutionTargets { .main }
  public static let title: LocalizedStringResource = "Get Unread Conversations"
  public static let description = IntentDescription("Get fresh unread Inline conversations for catching up. Returns total unread conversations and up to 20 results. Pass Next Cursor as After Cursor until it is empty. Results can be passed to Get Conversation Messages or Send to Inline Conversation. Does not mark anything read.")
  public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
  @Parameter(title: "After Cursor") public var afterCursor: String?
  public static var parameterSummary: some ParameterSummary { Summary("Get unread Inline conversations") { \.$afterCursor } }
  public init() {}
  public func perform() async throws -> some ReturnsValue<InlineSiriUnreadPage> {
    .result(value: InlineSiriUnreadPage(try await InlineIntentMessaging.unreadConversations(after: afterCursor)))
  }
}

@available(iOS 27.0, macOS 27.0, *)
public struct ReadInlineMessagesAIIntent: AppIntent {
  public static var allowedExecutionTargets: IntentExecutionTargets { .main }
  public static let title: LocalizedStringResource = "Get Conversation Messages"
  public static let description = IntentDescription("Get fresh Inline messages for reading, summarizing or replying. Returns original message bodies and authors, oldest first, up to 20 per page. Use Unread Only for catching up; turn it off for recent context. Pass Next Cursor as After Cursor until empty, even if a page has no incoming messages. Does not mark messages read. Pass a returned message to Reply to Inline Message. Attachments are not downloaded. Outgoing read receipts are not available.")
  public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
  @Parameter(title: "Conversation") public var conversation: InlineSiriConversationEntity
  @Parameter(title: "Unread Only", default: true) public var unreadOnly: Bool
  @Parameter(title: "After Cursor") public var afterCursor: String?
  public static var parameterSummary: some ParameterSummary {
    Summary("Read messages in \(\.$conversation)") { \.$unreadOnly; \.$afterCursor }
  }
  public init() {}
  public func perform() async throws -> some ReturnsValue<InlineSiriMessagePage> & ProvidesDialog {
    let page = try await InlineIntentMessaging.messages(
      chatID: conversation.id, unreadOnly: unreadOnly, after: afterCursor
    )
    return .result(
      value: InlineSiriMessagePage(page),
      dialog: InlineIntentDialogs.messagePage(page, chatTitle: conversation.displayName)
    )
  }
}

@available(iOS 27.0, macOS 27.0, *)
public struct SendToInlineConversationAIIntent: AppIntent {
  public static var allowedExecutionTargets: IntentExecutionTargets { .main }
  public static let title: LocalizedStringResource = "Send to Inline Conversation"
  public static let description = IntentDescription("Send plain text to an existing Inline DM or thread, with confirmation. Use a conversation returned by Get Unread Conversations or the conversation query.")
  public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
  @Parameter(title: "Conversation") public var conversation: InlineSiriConversationEntity
  @Parameter(title: "Message", inputOptions: String.IntentInputOptions(multiline: true)) public var text: String
  public static var parameterSummary: some ParameterSummary { Summary("Send \(\.$text) to \(\.$conversation)") }
  public init() {}
  public func perform() async throws -> some ReturnsValue<[InlineSiriMessageEntity]> {
    try InlineIntentService.validateMessage(text)
    let account = try await InlineIntentService.account()
    let id = conversation.id
    let target = try await InlineIntentMessaging.connected(account: account) { realtime in
      let inbox = try await InlineIntentMessaging.inbox(on: realtime, account: account)
      return try await InlineIntentMessaging.conversation(
        id,
        on: realtime,
        inbox: inbox,
        account: account
      ).conversation
    }
    try await requestConfirmation(actionName: .send, dialog: InlineIntentDialogs.confirmSend(to: target.chat))
    let sent = try await InlineIntentMessaging.send(text: text, chatID: id, account: account)
    return .result(value: sent.map(InlineSiriMessageEntity.init))
  }
}

@available(iOS 27.0, macOS 27.0, *)
public struct ReplyToInlineMessageAIIntent: AppIntent {
  public static var allowedExecutionTargets: IntentExecutionTargets { .main }
  public static let title: LocalizedStringResource = "Reply to Inline Message"
  public static let description = IntentDescription("Send a confirmed plain-text reply to a message returned by Get Conversation Messages, in its original DM or thread.")
  public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
  @Parameter(title: "Message") public var message: InlineSiriMessageEntity
  @Parameter(title: "Reply", inputOptions: String.IntentInputOptions(multiline: true)) public var text: String
  public static var parameterSummary: some ParameterSummary { Summary("Reply \(\.$text) to \(\.$message)") }
  public init() {}
  public func perform() async throws -> some ReturnsValue<[InlineSiriMessageEntity]> {
    try InlineIntentService.validateMessage(text)
    let account = try await InlineIntentService.account()
    guard let target = try await InlineIntentMessaging.resolve([message.id]).first else { throw InlineIntentError.unavailable }
    try InlineIntentService.validate(account)
    try await requestConfirmation(
      actionName: .send,
      dialog: InlineIntentDialogs.confirmReply(in: target.conversation.chat)
    )
    let sent = try await InlineIntentMessaging.send(text: text, chatID: target.id.chat.rawValue,
                                                   replyingTo: target.id.rawValue, account: account)
    return .result(value: sent.map(InlineSiriMessageEntity.init))
  }
}

@available(iOS 27.0, macOS 27.0, *)
public struct InlineSiriUnreadPage: TransientAppEntity {
  public init() {}
  public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Unread Conversations")
  @Property(title: "Conversations") public var conversations: [InlineSiriConversationEntity]
  @Property(title: "Total Unread Conversations") public var totalCount: Int
  @Property(title: "Next Cursor") public var nextCursor: String?
  public var displayRepresentation: DisplayRepresentation { .init(title: "\(totalCount) unread conversations") }
  init(_ page: InlineIntentConversationPage) {
    conversations = page.conversations.map(InlineSiriConversationEntity.init)
    totalCount = page.totalCount
    nextCursor = page.nextCursor
  }
}

@available(iOS 27.0, macOS 27.0, *)
public struct InlineSiriMessagePage: TransientAppEntity {
  public init() {}
  public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Inline Messages")
  @Property(title: "Messages") public var messages: [InlineSiriMessageEntity]
  @Property(title: "Next Cursor") public var nextCursor: String?
  public var displayRepresentation: DisplayRepresentation { .init(title: "\(messages.count) messages") }
  init(_ page: InlineIntentMessagePage) {
    messages = page.messages.map(InlineSiriMessageEntity.init)
    nextCursor = page.nextCursor
  }
}
#endif
