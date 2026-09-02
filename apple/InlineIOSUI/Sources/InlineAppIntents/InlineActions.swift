import AppIntents
import Foundation

public struct OpenInlineChatIntent: AppIntent {
  #if compiler(>=6.4)
  @available(iOS 27.0, macOS 27.0, *)
  public static var allowedExecutionTargets: IntentExecutionTargets { .main }
  #endif
  public static let title: LocalizedStringResource = "Open Chat"
  public static let description = IntentDescription("Open an existing Inline conversation. Requires a connection to verify access.")
  public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
  public static let openAppWhenRun = true
  @available(iOS 26.0, macOS 26.0, *)
  public static var supportedModes: IntentModes { .foreground }

  @Dependency(default: { () async throws -> InlineIntentNavigation in throw InlineIntentError.appNotReady })
  private var navigation: InlineIntentNavigation

  @Parameter(title: "Chat") public var chat: InlineChatEntity

  public static var parameterSummary: some ParameterSummary { Summary("Open \(\.$chat)") }

  public init() {}

  public func perform() async throws -> some IntentResult {
    let account = try await InlineIntentService.account()
    let resolved = try await InlineIntentService.resolve(chat.id)
    try await MainActor.run {
      try InlineIntentService.validate(account)
      guard resolved.id.accountID == account.userID else { throw InlineIntentError.accountChanged }
      guard navigation.openChat(resolved.peer, account.userID) else { throw InlineIntentError.accountChanged }
    }
    return .result()
  }
}

public struct FindInlineChatsIntent: AppIntent {
  #if compiler(>=6.4)
  @available(iOS 27.0, macOS 27.0, *)
  public static var allowedExecutionTargets: IntentExecutionTargets { .main }
  #endif
  public static let title: LocalizedStringResource = "Find Chats"
  public static let description = IntentDescription("Find up to 20 existing Inline chats by name or username. Leave the search empty for recent chats. Results contain names and context, not messages.")
  public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

  @Parameter(title: "Search", default: "") public var search: String

  public static var parameterSummary: some ParameterSummary { Summary("Find Inline chats matching \(\.$search)") }

  public init() {}

  public func perform() async throws -> some IntentResult & ReturnsValue<[InlineChatEntity]> {
    let chats = try await InlineIntentService.chats(search: search).map(InlineChatEntity.init)
    return .result(value: chats)
  }
}

public struct SendInlineMessageIntent: AppIntent {
  #if compiler(>=6.4)
  @available(iOS 27.0, macOS 27.0, *)
  public static var allowedExecutionTargets: IntentExecutionTargets { .main }
  #endif
  public static let title: LocalizedStringResource = "Send Message"
  public static let description = IntentDescription("Open Inline and send confirmed plain text to an existing chat. Requires a connection; messages are not queued for later.")
  public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
  public static let openAppWhenRun = true
  @available(iOS 26.0, macOS 26.0, *)
  public static var supportedModes: IntentModes { .foreground }

  @Parameter(title: "Chat") public var chat: InlineChatEntity
  @Parameter(title: "Message", inputOptions: String.IntentInputOptions(multiline: true)) public var message: String

  public static var parameterSummary: some ParameterSummary { Summary("Send \(\.$message) to \(\.$chat)") }

  public init() {}

  public func perform() async throws -> some IntentResult & ProvidesDialog {
    try InlineIntentService.validateMessage(message)
    let account = try await InlineIntentService.account()
    let resolved = try await InlineIntentService.resolve(chat.id)
    try InlineIntentService.validate(account)
    try await requestConfirmation(actionName: .send, dialog: InlineIntentDialogs.confirmSend(to: resolved))
    try await InlineIntentService.send(text: message, to: resolved.id.rawValue, account: account)
    return .result(dialog: "Message sent.")
  }
}

public struct SaveInlineNoteIntent: AppIntent {
  #if compiler(>=6.4)
  @available(iOS 27.0, macOS 27.0, *)
  public static var allowedExecutionTargets: IntentExecutionTargets { .main }
  #endif
  public static let title: LocalizedStringResource = "Save to Saved Messages"
  public static let description = IntentDescription("Open Inline and save text to yourself. Creates your Saved Messages chat on first use. Requires a connection; messages are not queued for later.")
  public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
  public static let openAppWhenRun = true
  @available(iOS 26.0, macOS 26.0, *)
  public static var supportedModes: IntentModes { .foreground }

  @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true)) public var text: String

  public static var parameterSummary: some ParameterSummary { Summary("Save \(\.$text) to Saved Messages") }

  public init() {}

  public func perform() async throws -> some IntentResult & ProvidesDialog {
    try InlineIntentService.validateMessage(text)
    try await InlineIntentService.saveNote(text)
    return .result(dialog: "Saved to Saved Messages.")
  }
}
