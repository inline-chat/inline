import AppIntents

/// App-only package: link from the iOS/Mac apps, never from share, notification or widget extensions.
/// Its adapters use the app's existing account, database and live connection owners. OS 27 actions
/// and queries additionally pin execution to `.main`; target membership protects earlier systems.
public struct InlineAppIntentsPackage: AppIntentsPackage {}

public struct InlineChatEntity: AppEntity {
  public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Inline Chat")
  public static let defaultQuery = InlineChatQuery()

  public let id: String
  @Property(title: "Name") public var name: String
  @Property(title: "Context") public var context: String
  @Property(title: "Unread Count") public var unreadCount: Int?

  public var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(name)", subtitle: "\(context)", image: .init(systemName: "bubble.left.and.bubble.right"))
  }

  init(_ chat: InlineIntentChat) {
    id = chat.id.rawValue
    name = chat.title
    context = chat.subtitle
    unreadCount = nil
  }

  init(_ conversation: InlineIntentConversation) {
    self.init(conversation.chat)
    unreadCount = Int(conversation.dialog.unreadCount)
  }
}

public struct InlineChatQuery: EntityStringQuery {
  #if compiler(>=6.4)
  @available(iOS 27.0, macOS 27.0, *)
  public static var allowedExecutionTargets: IntentExecutionTargets { .main }
  #endif
  public init() {}

  public func entities(for identifiers: [String]) async throws -> [InlineChatEntity] {
    try await InlineIntentService.chats(identifiers: identifiers).map(InlineChatEntity.init)
  }

  public func suggestedEntities() async throws -> [InlineChatEntity] {
    try await InlineIntentService.chats().map(InlineChatEntity.init)
  }

  public func entities(matching string: String) async throws -> [InlineChatEntity] {
    try await InlineIntentService.chats(search: string).map(InlineChatEntity.init)
  }
}
