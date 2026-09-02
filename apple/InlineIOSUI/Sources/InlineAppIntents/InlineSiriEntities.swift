#if compiler(>=6.4)
import AppIntents
import Auth
import CoreTransferable
import Foundation
import GeoToolbox
import InlineKit
import InlineProtocol
import LinkPresentation
import RealtimeV2
import UniformTypeIdentifiers

// Standard OS 27 shapes stay separate from the identifiers/types used by existing shortcuts.
// Queries resolve on demand. Declaring these entities does not index private message history.
@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .messages.messagePerson)
public struct InlineSiriPersonEntity {
  public static let defaultQuery = InlineSiriPersonQuery()
  public var id: String
  public var person: IntentPerson
  public var displayRepresentation: DisplayRepresentation { person.displayRepresentation }

  init(userID: Int64, accountID: Int64, name: String, username: String? = nil) {
    id = "p1:\(accountID):\(userID)"
    let username = username?.trimmingCharacters(in: .whitespacesAndNewlines)
    let handle = username.flatMap { $0.isEmpty ? nil : IntentPerson.Handle(applicationDefined: "inline:username:\($0)", label: "Inline") }
    person = IntentPerson(
      identifier: .applicationDefined(id),
      name: .displayName(name),
      handle: handle,
      aliases: [IntentPerson.Handle(applicationDefined: "inline:user:\(userID)", label: "Inline")],
      isMe: userID == accountID
    )
  }

  func userID(for accountID: Int64) -> Int64? {
    let parts = id.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0] == "p1", Int64(parts[1]) == accountID,
          let userID = Int64(parts[2]), userID > 0 else { return nil }
    return userID
  }

  var inlineDisplayName: String {
    switch person.name {
    case let .displayName(value): value
    case let .components(value): PersonNameComponentsFormatter.localizedString(from: value, style: .default)
    case .unknown: String(localized: "Inline User")
    @unknown default: String(localized: "Inline User")
    }
  }

  var username: String? {
    guard let handle = person.handle, case let .applicationDefined(value) = handle.value,
          value.hasPrefix("inline:username:") else { return nil }
    return String(value.dropFirst("inline:username:".count))
  }

  /// Entity payloads can outlive a rename. Only fresh server data may name a send recipient.
  func verified(account: AuthAccountMutationToken) async throws -> InlineSiriPersonEntity {
    guard let userID = userID(for: account.userID) else { throw InlineIntentError.unavailable }
    return try await InlineIntentMessaging.connected(account: account) { realtime in
      let inbox = try await InlineIntentMessaging.inbox(on: realtime, account: account)
      let user: InlineProtocol.User
      if let existing = inbox.users[userID] {
        user = existing
      } else if userID == account.userID {
        user = try await InlineIntentMessaging.currentUser(on: realtime, account: account)
      } else {
        let matches = try await InlineIntentMessaging.users(ids: [userID], on: realtime, account: account)
        guard let match = matches.first(where: { $0.id == userID }) else { throw InlineIntentError.recipientUnavailable }
        user = match
      }
      return Self(userID: user.id, accountID: account.userID, name: InlineIntentInbox.name(user), username: user.username)
    }
  }

  var confirmationName: String {
    if person.isMe { return String(localized: "Saved Messages") }
    if let username, !username.isEmpty { return "\(inlineDisplayName) (@\(username))" }
    return "\(inlineDisplayName) (\(id.split(separator: ":").last.map(String.init) ?? id))"
  }
}

@available(iOS 27.0, macOS 27.0, *)
extension InlineSiriPersonEntity: Transferable {
  public static var transferRepresentation: some TransferRepresentation {
    IntentValueRepresentation(exporting: \.person)
  }
}

@available(iOS 27.0, macOS 27.0, *)
public struct InlineSiriPersonQuery: EntityStringQuery, IntentValueQuery {
  public static var allowedExecutionTargets: IntentExecutionTargets { .main }
  public init() {}
  public func entities(for identifiers: [String]) async throws -> [InlineSiriPersonEntity] {
    guard identifiers.count <= 50 else { throw InlineIntentError.tooManyMessages }
    let account = try await InlineIntentService.account()
    return try await InlineIntentMessaging.connected(account: account) { realtime in
      let inbox = try await InlineIntentMessaging.inbox(on: realtime, account: account)
      let missing = Array(Set(identifiers.compactMap {
        Self.currentUserID(fromEntityIdentifier: $0, accountID: account.userID)
      }.filter { Self.person(for: $0, in: inbox) == nil }))
      let users = try await InlineIntentMessaging.users(ids: missing, on: realtime, account: account)
      return Self.rehydratedPeople(identifiers, in: inbox, fetchedUsers: users)
    }
  }
  public func suggestedEntities() async throws -> [InlineSiriPersonEntity] { try await entities(matching: "") }
  public func entities(matching string: String) async throws -> [InlineSiriPersonEntity] {
    let account = try await InlineIntentService.account()
    return try await InlineIntentMessaging.connected(account: account) { realtime in
      let inbox = try await InlineIntentMessaging.inbox(on: realtime, account: account)
      var values = Self.people(in: inbox, matching: string)
      let remoteUsers = try await InlineIntentMessaging.searchUsers(
        matching: string,
        on: realtime,
        account: account
      )
      values += remoteUsers.map {
        InlineSiriPersonEntity(
          userID: $0.id,
          accountID: account.userID,
          name: InlineIntentInbox.name($0),
          username: $0.username
        )
      }
      var seen = Set<String>()
      return Array(values.filter { seen.insert($0.id).inserted }.prefix(InlineIntentMessaging.batchLimit))
    }
  }
  public func values(for input: [IntentPerson]) async throws -> [InlineSiriPersonEntity] {
    guard input.count <= 20 else { throw InlineIntentError.tooManyMessages }
    let identifiers = input.map(Self.applicationIdentifiers)
    guard identifiers.reduce(0, { $0 + $1.count }) <= 50 else { throw InlineIntentError.tooManyMessages }
    let account = try await InlineIntentService.account()
    // Share one catalog snapshot across the batch and cache repeated name searches.
    return try await InlineIntentMessaging.connected(account: account) { realtime in
      let inbox = try await InlineIntentMessaging.inbox(on: realtime, account: account)
      var values: [InlineSiriPersonEntity] = []
      let currentUser = input.contains(where: \.isMe)
        ? try await InlineIntentMessaging.currentUser(on: realtime, account: account) : nil
      var nameMatches: [String: [InlineSiriPersonEntity]] = [:]
      for (person, personIdentifiers) in zip(input, identifiers) {
        if person.isMe {
          if let currentUser {
            values.append(InlineSiriPersonEntity(userID: currentUser.id, accountID: account.userID,
                                                 name: InlineIntentInbox.name(currentUser), username: currentUser.username))
          }
          continue
        }
        for identifier in personIdentifiers {
          if let value = try await Self.resolveApplicationIdentifier(identifier, in: inbox, on: realtime, account: account) {
            values.append(value)
          }
        }
        // An explicit Inline identity must never fall back to a different account/name.
        guard personIdentifiers.isEmpty, let name = Self.name(of: person) else { continue }
        let key = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if let matches = nameMatches[key] {
          values += matches
          continue
        }
        var matches = Self.people(matchingPersonName: name, in: inbox)
        let remote = try await InlineIntentMessaging.searchUsers(matching: name, on: realtime, account: account)
        matches += remote.map {
          InlineSiriPersonEntity(userID: $0.id, accountID: account.userID,
                                name: InlineIntentInbox.name($0), username: $0.username)
        }
        nameMatches[key] = matches
        values += matches
      }
      var seen = Set<String>()
      let candidates = Array(values.filter { seen.insert($0.id).inserted }.prefix(50))
      let missing = candidates.compactMap { $0.userID(for: account.userID) }.filter {
        Self.person(for: $0, in: inbox) == nil
      }
      let users = try await InlineIntentMessaging.users(ids: missing, on: realtime, account: account)
      return Self.rehydratedPeople(candidates.map(\.id), in: inbox, fetchedUsers: users + [currentUser].compactMap { $0 })
    }
  }

  static func rehydratedPeople(
    _ identifiers: [String], in inbox: InlineIntentInbox, fetchedUsers: [InlineProtocol.User]
  ) -> [InlineSiriPersonEntity] {
    let fetched = Dictionary(fetchedUsers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var seen = Set<Int64>()
    return identifiers.compactMap { identifier in
      guard let userID = currentUserID(fromEntityIdentifier: identifier, accountID: inbox.accountID),
            seen.insert(userID).inserted else { return nil }
      if let person = person(for: userID, in: inbox) { return person }
      guard let user = fetched[userID] else { return nil }
      return InlineSiriPersonEntity(userID: user.id, accountID: inbox.accountID,
                                   name: InlineIntentInbox.name(user), username: user.username)
    }
  }

  static func name(of person: IntentPerson) -> String? {
    let value: String
    switch person.name {
    case let .displayName(name): value = name
    case let .components(components): value = PersonNameComponentsFormatter.localizedString(from: components, style: .default)
    case .unknown: return nil
    @unknown default: return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  static func people(matchingPersonName name: String, in inbox: InlineIntentInbox) -> [InlineSiriPersonEntity] {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
    // Return every candidate; a name match is not sufficient authority to pick a recipient.
    return inbox.users.values.filter {
      InlineIntentInbox.name($0).localizedStandardContains(name) || $0.username.localizedStandardContains(name)
    }.sorted { $0.id < $1.id }.map {
      InlineSiriPersonEntity(userID: $0.id, accountID: inbox.accountID,
                            name: InlineIntentInbox.name($0), username: $0.username)
    }
  }

  private static func isInlineIdentifier(_ value: String) -> Bool {
    value.hasPrefix("p1:") || value.hasPrefix("inline:user:") || value.hasPrefix("inline:username:")
  }

  /// Stable identities outrank mutable usernames, including when system transfer puts the
  /// stable ID in an alias. A missing or wrong-account ID must never retarget a renamed handle.
  static func applicationIdentifiers(of person: IntentPerson) -> [String] {
    var identifiers: [String] = []
    if case let .applicationDefined(id) = person.identifier, isInlineIdentifier(id) {
      if id.hasPrefix("p1:") || id.hasPrefix("inline:user:") { return [id] }
      identifiers.append(id)
    }
    for handle in [person.handle].compactMap({ $0 }) + person.aliases {
      if case let .applicationDefined(id) = handle.value, isInlineIdentifier(id) { identifiers.append(id) }
    }
    var seen = Set<String>()
    identifiers = identifiers.filter { seen.insert($0).inserted }
    let scoped = identifiers.filter { $0.hasPrefix("p1:") }
    if !scoped.isEmpty { return scoped }
    let stable = identifiers.filter { $0.hasPrefix("inline:user:") }
    return stable.isEmpty ? identifiers : stable
  }

  private static func resolveApplicationIdentifier(
    _ identifier: String, in inbox: InlineIntentInbox, on realtime: RealtimeV2,
    account: AuthAccountMutationToken
  ) async throws -> InlineSiriPersonEntity? {
    if let local = person(forApplicationIdentifier: identifier, in: inbox) { return local }
    guard identifier.hasPrefix("inline:username:") else { return nil }
    let username = String(identifier.dropFirst("inline:username:".count))
    let matches = try await InlineIntentMessaging.searchUsers(matching: username, on: realtime, account: account)
      .filter { $0.username.caseInsensitiveCompare(username) == .orderedSame }
    guard matches.count == 1, let user = matches.first else { return nil }
    return InlineSiriPersonEntity(userID: user.id, accountID: account.userID,
                                 name: InlineIntentInbox.name(user), username: user.username)
  }
  private static func people(in inbox: InlineIntentInbox, matching search: String) -> [InlineSiriPersonEntity] {
    InlineIntentChatStore.fetch(in: inbox, search: search, directMessagesOnly: true).compactMap { chat in
      guard let id = chat.peer.asUserId() else { return nil }
      return InlineSiriPersonEntity(
        userID: id, accountID: chat.id.accountID, name: chat.title, username: chat.username
      )
    }
  }

  private static func person(for userID: Int64, in inbox: InlineIntentInbox) -> InlineSiriPersonEntity? {
    if let user = inbox.users[userID] {
      return InlineSiriPersonEntity(userID: user.id, accountID: inbox.accountID,
                                   name: InlineIntentInbox.name(user), username: user.username)
    }
    guard let chat = inbox.conversations.first(where: { $0.chat.peer == .user(id: userID) })?.chat else {
      return nil
    }
    return InlineSiriPersonEntity(
      userID: userID, accountID: inbox.accountID, name: chat.title, username: chat.username
    )
  }

  static func person(
    forApplicationIdentifier identifier: String,
    in inbox: InlineIntentInbox
  ) -> InlineSiriPersonEntity? {
    if identifier.hasPrefix("p1:"),
       let userID = currentUserID(fromEntityIdentifier: identifier, accountID: inbox.accountID) {
      return person(for: userID, in: inbox) ?? InlineSiriPersonEntity(
        userID: userID,
        accountID: inbox.accountID,
        name: String(localized: "Inline User")
      )
    }
    if identifier.hasPrefix("inline:user:"),
       let userID = Int64(identifier.dropFirst("inline:user:".count)), userID > 0 {
      return person(for: userID, in: inbox) ?? InlineSiriPersonEntity(
        userID: userID,
        accountID: inbox.accountID,
        name: String(localized: "Inline User")
      )
    }
    if identifier.hasPrefix("inline:username:") {
      let username = identifier.dropFirst("inline:username:".count)
      if !username.isEmpty,
         let user = inbox.users.values.first(where: { $0.username.caseInsensitiveCompare(String(username)) == .orderedSame }) {
        return InlineSiriPersonEntity(userID: user.id, accountID: inbox.accountID,
                                     name: InlineIntentInbox.name(user), username: user.username)
      }
      guard !username.isEmpty,
            let chat = inbox.conversations.first(where: {
              $0.chat.peer.asUserId() != nil && $0.chat.username?.caseInsensitiveCompare(String(username)) == .orderedSame
            })?.chat,
            let userID = chat.peer.asUserId()
      else { return nil }
      return InlineSiriPersonEntity(
        userID: userID, accountID: inbox.accountID, name: chat.title, username: chat.username
      )
    }
    return nil
  }

  private static func currentUserID(fromEntityIdentifier value: String, accountID: Int64) -> Int64? {
    let parts = value.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0] == "p1", Int64(parts[1]) == accountID,
          let userID = Int64(parts[2]), userID > 0 else { return nil }
    return userID
  }
}

@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .messages.conversation)
public struct InlineSiriConversationEntity {
  public static let defaultQuery = InlineSiriConversationQuery()
  public var id: String
  public var recipients: [InlineSiriPersonEntity]
  public var displayName: String
  public var previewText: AttributedString
  public var conversationName: String?
  public var isRead: Bool
  public var attributes: Set<InlineSiriConversationAttribute>
  public var dateLastActive: Date?
  @Property(title: "Context") public var context: String
  @Property(title: "Unread Count") public var unreadCount: Int
  public var displayRepresentation: DisplayRepresentation {
    .init(title: "\(displayName)", subtitle: "\(context)")
  }

  init(_ value: InlineIntentConversation) {
    id = value.chat.id.rawValue
    displayName = value.chat.title
    conversationName = value.chat.title
    context = value.chat.subtitle
    previewText = AttributedString(value.previewText)
    unreadCount = Int(value.dialog.unreadCount)
    isRead = !value.isUnread
    attributes = value.dialog.pinned ? [.favorited] : []
    dateLastActive = Date(timeIntervalSince1970: TimeInterval(value.lastActivityDate))
    recipients = value.chat.peer.asUserId().map {
      [InlineSiriPersonEntity(
        userID: $0,
        accountID: value.chat.id.accountID,
        name: value.chat.title,
        username: value.chat.username
      )]
    } ?? []
  }
}

@available(iOS 27.0, macOS 27.0, *)
public struct InlineSiriConversationQuery: EntityStringQuery {
  public static var allowedExecutionTargets: IntentExecutionTargets { .main }
  public init() {}
  public func entities(for identifiers: [String]) async throws -> [InlineSiriConversationEntity] {
    try await InlineIntentMessaging.conversations(identifiers: identifiers)
      .map(InlineSiriConversationEntity.init)
  }
  public func suggestedEntities() async throws -> [InlineSiriConversationEntity] {
    try await InlineIntentMessaging.conversations().map(InlineSiriConversationEntity.init)
  }
  public func entities(matching string: String) async throws -> [InlineSiriConversationEntity] {
    let account = try await InlineIntentService.account()
    return try await InlineIntentMessaging.connected(account: account) { realtime in
      let inbox = try await InlineIntentMessaging.inbox(on: realtime, account: account)
      return InlineIntentChatStore.fetch(in: inbox, search: string).compactMap {
        try? inbox.conversation($0.id.rawValue)
      }.map(InlineSiriConversationEntity.init)
    }
  }
}

@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .messages.message)
public struct InlineSiriMessageEntity: IndexedEntity {
  // Apple's mutation schemas require a resolvable/index-capable message type. Conformance
  // does not index anything: we donate no history and resolve explicit read results by ID.
  public static let defaultQuery = InlineSiriMessageQuery()
  public var id: String
  public var messageType: InlineSiriMessageType
  public var author: InlineSiriPersonEntity
  public var isRead: Bool
  public var attributes: Set<InlineSiriMessageAttribute>
  public var conversation: InlineSiriConversationEntity
  public var date: Date
  public var subject: AttributedString?
  public var body: AttributedString?
  public var attachments: [IntentFile]
  public var audioMessage: IntentFile?
  public var customAttachments: [InlineSiriCustomAttachment]
  public var locations: [PlaceDescriptor]
  public var links: [LinkPresentation.LinkMetadata]
  public var messageEffect: InlineSiriMessageEffect?
  public var reaction: InlineSiriMessageReaction?
  public var referencedMessage: InlineSiriMessageEntity?
  public var notificationIdentifier: String?
  public var displayRepresentation: DisplayRepresentation {
    .init(title: "\(body ?? AttributedString(""))", subtitle: "\(conversation.displayName)")
  }
  init(_ message: InlineIntentMessage) {
    id = message.id.rawValue
    messageType = .unspecified
    author = InlineSiriPersonEntity(
      userID: message.source.fromID,
      accountID: message.id.chat.accountID,
      name: message.author,
      username: message.authorUsername
    )
    isRead = message.isRead
    attributes = []
    conversation = InlineSiriConversationEntity(message.conversation)
    date = Date(timeIntervalSince1970: TimeInterval(message.source.date))
    body = AttributedString(message.text)
    attachments = []
    customAttachments = []
    locations = []
    links = []
  }
}

@available(iOS 27.0, macOS 27.0, *)
extension InlineSiriMessageEntity: Transferable {
  public static var transferRepresentation: some TransferRepresentation {
    DataRepresentation(exportedContentType: .plainText) { entity in
      let text = entity.body.map { String($0.characters) } ?? ""
      return Data(text.utf8)
    }
  }
}

@available(iOS 27.0, macOS 27.0, *)
public struct InlineSiriMessageQuery: EntityQuery {
  public static var allowedExecutionTargets: IntentExecutionTargets { .main }
  public init() {}
  public func entities(for identifiers: [String]) async throws -> [InlineSiriMessageEntity] {
    try await InlineIntentMessaging.resolve(identifiers).map(InlineSiriMessageEntity.init)
  }
}

@available(iOS 27.0, macOS 27.0, *)
@AppEntity(schema: .messages.customAttachment)
public struct InlineSiriCustomAttachment {
  public static let defaultQuery = Query()
  public var id: String
  public var sourceName: AttributedString?
  public var description: AttributedString?
  public var displayRepresentation: DisplayRepresentation { .init(title: "Attachment") }
  public struct Query: EntityQuery {
    public static var allowedExecutionTargets: IntentExecutionTargets { .main }
    public init() {}
    public func entities(for identifiers: [String]) async throws -> [InlineSiriCustomAttachment] { [] }
  }
}

@available(iOS 27.0, macOS 27.0, *)
@AppEnum(schema: .messages.conversationAttribute)
public enum InlineSiriConversationAttribute: String {
  case favorited
  public static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.favorited: "Favorited"]
}
@available(iOS 27.0, macOS 27.0, *)
@AppEnum(schema: .messages.messageType)
public enum InlineSiriMessageType: String {
  case unspecified
  public static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.unspecified: "Message"]
}
@available(iOS 27.0, macOS 27.0, *)
@AppEnum(schema: .messages.messageAttribute)
public enum InlineSiriMessageAttribute: String {
  case favorited
  public static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.favorited: "Favorited"]
}
@available(iOS 27.0, macOS 27.0, *)
@AppEnum(schema: .messages.messageEffect)
public enum InlineSiriMessageEffect: String {
  case love
  public static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.love: "Love"]
}
@available(iOS 27.0, macOS 27.0, *)
@AppEnum(schema: .messages.customReaction)
public enum InlineSiriCustomReaction: String {
  case sticker
  public static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.sticker: "Sticker"]
}
@available(iOS 27.0, macOS 27.0, *)
@UnionValue
public enum InlineSiriMessageReaction: Sendable { case customReaction(InlineSiriCustomReaction) }
#endif
