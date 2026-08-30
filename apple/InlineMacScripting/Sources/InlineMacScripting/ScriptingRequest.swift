import CoreFoundation
import Foundation

public enum ScriptingRequest: Equatable, Sendable {
  case show
  case account
  case spaces(limit: Int, offset: Int)
  case users(query: String?, spaceID: Int64?, limit: Int, offset: Int)
  case user(Int64)
  case searchUsers(query: String, limit: Int)
  case chats(query: String?, spaceID: Int64?, limit: Int, offset: Int)
  case createThread(title: String?, spaceID: Int64?, participantIDs: [Int64], isPublic: Bool)
  case currentChat
  case openChat(Int64)
  case messages(chatID: Int64, limit: Int, before: Int64?)
  case send(text: String, chatID: Int64, requestID: Int64)
  case link(Int64)

  static func decode(code: UInt32, direct: Any?, arguments: [String: Any]) throws -> Self {
    let input = Arguments(direct: direct, values: arguments)
    switch code {
    case fourCC("show"): return .show
    case fourCC("acct"): return .account
    case fourCC("spcs"):
      return try .spaces(limit: input.limit(default: 100), offset: input.offset())
    case fourCC("usrs"), fourCC("ufnd"):
      let query = code == fourCC("ufnd") ? try input.userQuery() : nil
      return try .users(query: query, spaceID: input.optionalID("spaceID"), limit: input.limit(default: 100), offset: input.offset())
    case fourCC("uinf"): return try .user(input.id(direct, name: "user id"))
    case fourCC("usrh"):
      return try .searchUsers(query: input.userQuery(), limit: input.limit(default: 20, maximum: 20))
    case fourCC("chat"), fourCC("find"):
      let query = code == fourCC("find") ? try input.text(direct, name: "query", maximum: 200) : nil
      return try .chats(query: query, spaceID: input.optionalID("spaceID"), limit: input.limit(default: 100), offset: input.offset())
    case fourCC("curr"): return .currentChat
    case fourCC("crth"):
      let spaceID = try input.optionalID("spaceID")
      let participantIDs = try input.ids("participantIDs")
      let isPublic = try input.boolean("isPublic", default: false)
      if isPublic && (spaceID == nil || !participantIDs.isEmpty) {
        throw ScriptingError(-1700, "Public threads require a space and no explicit participant IDs.")
      }
      return try .createThread(title: input.title(), spaceID: spaceID, participantIDs: participantIDs, isPublic: isPublic)
    case fourCC("open"): return try .openChat(input.id(direct, name: "chat id"))
    case fourCC("msgs"):
      return try .messages(chatID: input.id(direct, name: "chat id"), limit: input.limit(default: 20), before: input.optionalID("beforeID"))
    case fourCC("send"):
      return try .send(
        text: input.text(direct, name: "message", maximum: 4096),
        chatID: input.id(arguments["chatID"], name: "to chat"),
        requestID: input.optionalID("requestID") ?? Int64.random(in: 1...Int64.max)
      )
    case fourCC("link"): return try .link(input.id(direct, name: "chat id"))
    default: throw ScriptingError(-1708, "This AppleScript command is not supported.")
    }
  }

  public var timeoutError: ScriptingError {
    if case .createThread = self { return .creationOutcomeUnknown }
    return .timeout
  }
}

private struct Arguments {
  let direct: Any?
  let values: [String: Any]

  func id(_ value: Any?, name: String) throws -> Int64 {
    guard let value else { throw ScriptingError(-1701, "Missing \(name).") }
    guard let text = value as? String, !text.isEmpty,
          text.utf8.allSatisfy({ (48...57).contains($0) }),
          let id = Int64(text), id > 0
    else { throw ScriptingError(-1700, "\(name) must be a positive 64-bit decimal ID supplied as text.") }
    return id
  }

  func optionalID(_ key: String) throws -> Int64? {
    guard let value = values[key] else { return nil }
    return try id(value, name: key)
  }

  func ids(_ key: String) throws -> [Int64] {
    guard let value = values[key] else { return [] }
    guard let list = value as? [Any], list.count <= 100 else {
      throw ScriptingError(-1700, "\(key) must be a list of at most 100 decimal-text user IDs.")
    }
    var seen: Set<Int64> = []
    return try list.compactMap {
      let parsedID = try id($0, name: key)
      return seen.insert(parsedID).inserted ? parsedID : nil
    }
  }

  func title() throws -> String? {
    guard let direct else { return nil }
    guard let title = direct as? String, title.utf16.count <= 150 else {
      throw ScriptingError(-1700, "The title must be text with at most 150 UTF-16 units.")
    }
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  func userQuery() throws -> String {
    var query = try text(direct, name: "query", maximum: 200).trimmingCharacters(in: .whitespacesAndNewlines)
    if query.hasPrefix("@") { query.removeFirst() }
    guard !query.isEmpty else { throw ScriptingError(-1700, "Enter a name or username after @.") }
    return query
  }

  func boolean(_ key: String, default fallback: Bool) throws -> Bool {
    guard let value = values[key] else { return fallback }
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
      throw ScriptingError(-1700, "\(key) must be true or false.")
    }
    return number.boolValue
  }

  func text(_ value: Any?, name: String, maximum: Int) throws -> String {
    guard let value else { throw ScriptingError(-1701, "Missing \(name).") }
    guard let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          text.utf16.count <= maximum
    else { throw ScriptingError(-1700, "\(name) must contain 1–\(maximum) UTF-16 units of nonblank text.") }
    return text
  }

  func limit(default fallback: Int, maximum: Int = 100) throws -> Int {
    try integer("limit", default: fallback, range: 1...maximum)
  }

  func offset() throws -> Int {
    try integer("offset", default: 0, range: 0...1_000_000)
  }

  private func integer(_ key: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
    guard let value = values[key] else { return fallback }
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          range.contains(number.intValue), number.doubleValue == Double(number.intValue)
    else { throw ScriptingError(-1700, "\(key) must be an integer from \(range.lowerBound) to \(range.upperBound).") }
    return number.intValue
  }
}

public struct ScriptingError: Error, Equatable, Sendable {
  public let number: Int
  public let message: String

  public init(_ number: Int, _ message: String) {
    self.number = number
    self.message = message
  }

  public static let unavailable = Self(-10004, "Sign in to Inline and wait for account loading to finish.")
  public static let notFound = Self(-1728, "The requested item is not in the available local cache. Open it in Inline first.")
  public static let timeout = Self(-1712, "Inline timed out. A send may have completed; check the chat before retrying, and reuse your request id if supplied.")
  public static let creationOutcomeUnknown = Self(-1712, "Thread creation timed out and may have completed. Check Inline before retrying; repeating create thread can create a duplicate.")
  public static let failed = Self(-10000, "Inline could not complete this command.")
}

func fourCC(_ text: String) -> UInt32 {
  precondition(text.utf8.count == 4)
  return text.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
}
