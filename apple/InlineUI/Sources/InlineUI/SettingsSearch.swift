import Foundation

/// One searchable setting. `context` holds broader labels such as the section and category title.
public struct SettingsSearchEntry<ID: Hashable & Sendable>: Sendable {
  public let id: ID
  public let title: String
  public let keywords: [String]
  public let context: [String]

  public init(id: ID, title: String, keywords: [String] = [], context: [String] = []) {
    self.id = id
    self.title = title
    self.keywords = keywords
    self.context = context
  }
}

/// Pure, synchronous settings matcher shared by the Apple settings screens.
///
/// Every query token must prefix-match a word in the title, keywords, or context. Results are ranked by
/// title prefix > title word > keyword > context, with ties keeping the input order.
public enum SettingsSearch {
  public static func results<ID>(for query: String, in entries: [SettingsSearchEntry<ID>]) -> [ID] {
    let tokens = words(in: query)
    guard !tokens.isEmpty else { return [] }

    let scored: [(index: Int, score: Int, id: ID)] = entries.enumerated().compactMap { index, entry in
      guard let score = score(entry, tokens: tokens) else { return nil }
      return (index, score, entry.id)
    }

    return scored
      .sorted { lhs, rhs in
        lhs.score != rhs.score ? lhs.score > rhs.score : lhs.index < rhs.index
      }
      .map(\.id)
  }

  static func words(in text: String) -> [String] {
    normalized(text)
      .split { !$0.isLetter && !$0.isNumber }
      .map(String.init)
  }

  private static func normalized(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
  }

  private static func score<ID>(_ entry: SettingsSearchEntry<ID>, tokens: [String]) -> Int? {
    let title = normalized(entry.title)
    let titleWords = words(in: entry.title)
    let keywordWords = entry.keywords.flatMap(words(in:))
    let contextWords = entry.context.flatMap(words(in:))

    var total = 0
    for token in tokens {
      let tokenScore: Int
      if title.hasPrefix(token) {
        tokenScore = Score.titlePrefix
      } else if titleWords.contains(where: { $0.hasPrefix(token) }) {
        tokenScore = Score.titleWord
      } else if keywordWords.contains(where: { $0.hasPrefix(token) }) {
        tokenScore = Score.keyword
      } else if contextWords.contains(where: { $0.hasPrefix(token) }) {
        tokenScore = Score.context
      } else {
        return nil
      }
      total += tokenScore
    }
    return total
  }

  private enum Score {
    static let titlePrefix = 8
    static let titleWord = 4
    static let keyword = 2
    static let context = 1
  }
}
