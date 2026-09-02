import AppIntents
import Foundation

public struct FindUnreadInlineChatsIntent: AppIntent {
  #if compiler(>=6.4)
  @available(iOS 27.0, macOS 27.0, *)
  public static var allowedExecutionTargets: IntentExecutionTargets { .main }
  #endif
  public static let title: LocalizedStringResource = "Find Unread Chats"
  public static let description = IntentDescription("Check Inline for conversations with unread messages or an unread reminder. Returns the total count and up to 20 chats. Pass Next Cursor back as After Cursor for the next page. Does not mark anything read.")
  public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
  @Parameter(title: "After Cursor") public var afterCursor: String?
  public static var parameterSummary: some ParameterSummary { Summary("Find unread chats") { \.$afterCursor } }
  public init() {}
  public func perform() async throws -> some ReturnsValue<InlineUnreadChatPage> & ProvidesDialog {
    let page = try await InlineIntentMessaging.unreadConversations(after: afterCursor)
    return .result(value: InlineUnreadChatPage(page), dialog: "\(page.totalCount) unread conversations. This page contains \(page.conversations.count).")
  }
}

public struct ReadInlineMessagesIntent: AppIntent {
  #if compiler(>=6.4)
  @available(iOS 27.0, macOS 27.0, *)
  public static var allowedExecutionTargets: IntentExecutionTargets { .main }
  #endif
  public static let title: LocalizedStringResource = "Get Messages"
  public static let description = IntentDescription("Get a page of up to 20 messages from Inline for reading or summarizing. Returns author, date, text and read state. Never marks messages read. Pass Next Cursor back when more may be available, even if this page has no incoming messages.")
  public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
  @Parameter(title: "Chat") public var chat: InlineChatEntity
  @Parameter(title: "Unread Only", default: true) public var unreadOnly: Bool
  @Parameter(title: "After Cursor") public var afterCursor: String?
  public static var parameterSummary: some ParameterSummary {
    Summary("Get messages in \(\.$chat)") { \.$unreadOnly; \.$afterCursor }
  }
  public init() {}
  public func perform() async throws -> some ReturnsValue<InlineMessagePage> & ProvidesDialog {
    let page = try await InlineIntentMessaging.messages(chatID: chat.id, unreadOnly: unreadOnly, after: afterCursor)
    return .result(value: InlineMessagePage(page), dialog: InlineIntentDialogs.messagePage(page, chatTitle: chat.name))
  }
}

public struct ReplyToInlineMessageIntent: AppIntent {
  #if compiler(>=6.4)
  @available(iOS 27.0, macOS 27.0, *)
  public static var allowedExecutionTargets: IntentExecutionTargets { .main }
  #endif
  public static let title: LocalizedStringResource = "Reply to Message"
  public static let description = IntentDescription("Send a plain-text reply to an existing Inline message, in the same DM or thread. Requires a connection. Confirms before sending.")
  public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
  @Parameter(title: "Message") public var target: InlineMessageEntity
  @Parameter(title: "Reply", inputOptions: String.IntentInputOptions(multiline: true)) public var text: String
  public static var parameterSummary: some ParameterSummary { Summary("Reply \(\.$text) to \(\.$target)") }
  public init() {}
  public func perform() async throws -> some ReturnsValue<[InlineMessageEntity]> & ProvidesDialog {
    try InlineIntentService.validateMessage(text)
    let account = try await InlineIntentService.account()
    guard let message = try await InlineIntentMessaging.resolve([target.id]).first else { throw InlineIntentError.unavailable }
    try InlineIntentService.validate(account)
    try await requestConfirmation(
      actionName: .send,
      dialog: InlineIntentDialogs.confirmReply(in: message.conversation.chat)
    )
    let sent = try await InlineIntentMessaging.send(text: text, chatID: message.id.chat.rawValue,
                                                   replyingTo: message.id.rawValue, account: account)
    return .result(value: sent.map(InlineMessageEntity.init), dialog: "Reply sent.")
  }
}
