import Foundation
import InlineKit

/// A message hit from this device's index or from the account-wide search.
public enum InlineSearchMessageResult: Identifiable, Sendable, Hashable {
  case local(LocalMessageSearchResult)
  case cloud(CloudMessageSearchResult)

  public var id: String {
    switch self {
      case let .local(result): result.id
      case let .cloud(result): result.id
    }
  }

  public var peer: Peer {
    switch self {
      case let .local(result): result.peer
      case let .cloud(result): result.peer
    }
  }

  public var chatId: Int64 {
    switch self {
      case let .local(result): result.chatId
      case let .cloud(result): result.chatId
    }
  }

  public var messageId: Int64 {
    switch self {
      case let .local(result): result.messageId
      case let .cloud(result): result.messageId
    }
  }

  public var date: Date {
    switch self {
      case let .local(result): result.message.message.date
      case let .cloud(result): result.date
    }
  }

  public var title: String {
    switch self {
      case let .local(result): result.title
      case let .cloud(result): result.title
    }
  }

  public var contextTitle: String? {
    switch self {
      case let .local(result): result.contextTitle
      case let .cloud(result): result.contextTitle
    }
  }

  public var snippet: String {
    switch self {
      case let .local(result): result.snippet
      case let .cloud(result): result.snippet
    }
  }

  /// Matched words in `snippet`, in UTF-16 code units. Local hits don't carry them.
  public var highlights: [NSRange] {
    switch self {
      case .local: []
      case let .cloud(result): result.highlights
    }
  }

  public var senderName: String? {
    switch self {
      case let .local(result): result.senderName
      case let .cloud(result): result.senderName
    }
  }

  /// One line for a result row: the sender in group chats, then the excerpt
  /// starting just before its first match, matched words strongly emphasized.
  public var highlightedSnippet: AttributedString {
    let (text, ranges) = Self.trimmed(snippet, highlights: highlights)
    var attributed = AttributedString(text)
    for highlight in ranges {
      guard let range = Range(highlight, in: text),
            let lower = AttributedString.Index(range.lowerBound, within: attributed),
            let upper = AttributedString.Index(range.upperBound, within: attributed)
      else { continue }
      attributed[lower ..< upper].inlinePresentationIntent = .stronglyEmphasized
    }
    guard let senderName, senderName.isEmpty == false else { return attributed }
    return AttributedString("\(senderName): ") + attributed
  }

  /// Time today, the weekday within a week, else the date (with a year if it's not this one).
  public func dateLabel(now: Date = Date(), calendar: Calendar = .current) -> String {
    let date = date
    if calendar.isDate(date, inSameDayAs: now) {
      return date.formatted(date: .omitted, time: .shortened)
    }
    if let days = calendar.dateComponents([.day], from: date, to: now).day, days >= 0, days < 7 {
      return date.formatted(.dateTime.weekday(.abbreviated))
    }
    if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
      return date.formatted(.dateTime.month(.abbreviated).day())
    }
    return date.formatted(date: .abbreviated, time: .omitted)
  }

  /// A match far into the excerpt would be cut off on one line. Start a few
  /// characters before it, at a word boundary, and shift the ranges.
  static func trimmed(_ text: String, highlights: [NSRange]) -> (String, [NSRange]) {
    let string = text as NSString
    guard let first = highlights.map(\.location).min(), first > 24 else { return (text, highlights) }
    var start = first - 12
    let whitespace = CharacterSet.whitespacesAndNewlines
    // Back up to the start of the word containing `start`.
    while start > 0, let scalar = Unicode.Scalar(string.character(at: start - 1)), !whitespace.contains(scalar) {
      start -= 1
    }
    start = string.rangeOfComposedCharacterSequence(at: start).location
    guard start > 0, start < string.length else { return (text, highlights) }
    let prefix = "…"
    let shift = (prefix as NSString).length - start
    let ranges = highlights.compactMap { range -> NSRange? in
      guard range.location >= start else { return nil }
      return NSRange(location: range.location + shift, length: range.length)
    }
    return (prefix + string.substring(from: start), ranges)
  }

  public var chat: Chat? {
    switch self {
      case let .local(result): result.chat
      case let .cloud(result): result.chat
    }
  }

  public var peerUser: User? {
    switch self {
      case let .local(result): result.peerUser
      case let .cloud(result): result.peerUser
    }
  }

  /// False for an account-wide hit in a chat this device never stored. Opening
  /// one fetches the chat first.
  public var isChatStored: Bool {
    switch self {
      case .local: true
      case let .cloud(result): result.isChatStored
    }
  }

  /// Without a server page (offline, or not answered yet) the list is local only,
  /// in its own order. With one, all hits are newest first: the server's, plus
  /// local hits it didn't return, such as prefix matches. While the server has
  /// older pages, a local hit older than its oldest loaded hit waits for them,
  /// so it isn't listed between pages. An incomplete index can miss local hits,
  /// so they all show.
  public static func merge(
    cloud: [CloudMessageSearchResult]?,
    local: [LocalMessageSearchResult],
    cloudHasMore: Bool = false,
    indexIncomplete: Bool = false
  ) -> [InlineSearchMessageResult] {
    guard let cloud else { return local.map(Self.local) }
    let cutoff = cloudHasMore && indexIncomplete == false ? cloud.map(\.date).min() : nil
    var seen = Set<String>()
    var merged: [InlineSearchMessageResult] = []
    merged.reserveCapacity(cloud.count + local.count)
    for result in cloud where seen.insert(result.id).inserted {
      merged.append(.cloud(result))
    }
    for result in local where seen.insert(result.id).inserted {
      if let cutoff, result.message.message.date < cutoff { continue }
      merged.append(.local(result))
    }
    return merged.sorted { lhs, rhs in
      if lhs.date != rhs.date { return lhs.date > rhs.date }
      if lhs.chatId != rhs.chatId { return lhs.chatId > rhs.chatId }
      return lhs.messageId > rhs.messageId
    }
  }
}

public protocol InlineCloudMessageSearching: Sendable {
  func searchMessages(
    query: String,
    scope: CloudMessageSearchScope,
    cursor: String?
  ) async throws -> CloudMessageSearchPage
}

public struct InlineApiCloudMessageSearchClient: InlineCloudMessageSearching {
  public init() {}

  public func searchMessages(
    query: String,
    scope: CloudMessageSearchScope,
    cursor: String?
  ) async throws -> CloudMessageSearchPage {
    try await CloudMessageSearch.search(query: query, scope: scope, cursor: cursor)
  }
}

extension InlineSearchScope {
  var cloudMessageScope: CloudMessageSearchScope {
    CloudMessageSearchScope(
      spaceId: spaceId,
      homeOnly: spaceId == nil && includeSpaceChatsInHome == false,
      includeArchived: includeArchived
    )
  }
}
