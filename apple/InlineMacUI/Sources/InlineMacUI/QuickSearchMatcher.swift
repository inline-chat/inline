import Foundation

public enum QuickSearchMatcher {
  public struct PreparedQuery: Sendable {
    let normalized: String
    let compact: String
    let tokens: [String]
    let apostropheInsensitiveNormalized: String
    let apostropheInsensitiveCompact: String
    let apostropheInsensitiveTokens: [String]
  }

  public struct SearchField: Sendable {
    public let value: String
    public let boost: Int

    public init(value: String, boost: Int) {
      self.value = value
      self.boost = boost
    }
  }

  public static func prepareQuery(_ query: String) -> PreparedQuery? {
    let normalized = normalize(query)
    guard normalized.isEmpty == false else { return nil }

    let apostropheInsensitiveNormalized = normalize(query, droppingApostrophes: true)
    return PreparedQuery(
      normalized: normalized,
      compact: normalized.replacingOccurrences(of: " ", with: ""),
      tokens: tokens(from: normalized),
      apostropheInsensitiveNormalized: apostropheInsensitiveNormalized,
      apostropheInsensitiveCompact: apostropheInsensitiveNormalized.replacingOccurrences(of: " ", with: ""),
      apostropheInsensitiveTokens: tokens(from: apostropheInsensitiveNormalized)
    )
  }

  public static func score(query: String, fields: [SearchField]) -> Int? {
    guard let preparedQuery = prepareQuery(query) else { return nil }
    return score(preparedQuery: preparedQuery, fields: fields)
  }

  public static func score(preparedQuery: PreparedQuery, fields: [SearchField]) -> Int? {
    var best: Int?
    for field in fields {
      let normalizedField = normalize(field.value)
      guard normalizedField.isEmpty == false else { continue }
      let apostropheInsensitiveField = normalize(field.value, droppingApostrophes: true)
      guard let fieldScore = scoreField(
        preparedQuery: preparedQuery,
        field: normalizedField,
        apostropheInsensitiveField: apostropheInsensitiveField
      ) else { continue }
      let boostedScore = fieldScore + field.boost
      if let best, boostedScore <= best {
        continue
      }
      best = boostedScore
    }
    return best
  }

  private static func scoreField(
    preparedQuery: PreparedQuery,
    field: String,
    apostropheInsensitiveField: String
  ) -> Int? {
    let penaltyLength = field.count
    let directScore = rawScore(
      normalizedQuery: preparedQuery.normalized,
      compactQuery: preparedQuery.compact,
      queryTokens: preparedQuery.tokens,
      field: field,
      penaltyLength: penaltyLength
    )
    let apostropheInsensitiveScore = rawScore(
      normalizedQuery: preparedQuery.apostropheInsensitiveNormalized,
      compactQuery: preparedQuery.apostropheInsensitiveCompact,
      queryTokens: preparedQuery.apostropheInsensitiveTokens,
      field: apostropheInsensitiveField,
      penaltyLength: penaltyLength
    )

    switch (directScore, apostropheInsensitiveScore) {
      case let (lhs?, rhs?):
        return max(lhs, rhs)
      case let (lhs?, nil):
        return lhs
      case let (nil, rhs?):
        return rhs
      case (nil, nil):
        return nil
    }
  }

  private static func rawScore(
    normalizedQuery: String,
    compactQuery: String,
    queryTokens: [String],
    field: String,
    penaltyLength: Int
  ) -> Int? {
    var score = 0
    let fieldTokens = tokens(from: field)

    if field == normalizedQuery {
      score += 12_000
    }

    if field.hasPrefix(normalizedQuery) {
      score += 9_000
    }

    if let wordPrefixIndex = fieldTokens.firstIndex(where: { $0.hasPrefix(normalizedQuery) }) {
      score += 7_000 - min(wordPrefixIndex * 120, 600)
    }

    if let range = field.range(of: normalizedQuery) {
      let position = field.distance(from: field.startIndex, to: range.lowerBound)
      score += 5_000 - min(position * 25, 1_000)
    }

    if queryTokens.isEmpty == false {
      var matchedTokenCount = 0
      for token in queryTokens {
        if fieldTokens.contains(token) {
          score += 1_600
          matchedTokenCount += 1
          continue
        }

        if fieldTokens.contains(where: { $0.hasPrefix(token) }) {
          score += 1_200
          matchedTokenCount += 1
          continue
        }

        if let tokenRange = field.range(of: token) {
          let position = field.distance(from: field.startIndex, to: tokenRange.lowerBound)
          score += 800 - min(position * 15, 500)
          matchedTokenCount += 1
        }
      }

      if matchedTokenCount == queryTokens.count {
        score += 1_500
      } else if matchedTokenCount == 0, score == 0 {
        return nil
      }
    }

    if score > 0, compactQuery.count >= 3, isSubsequence(compactQuery, of: field) {
      score += 180
    }

    guard score > 0 else { return nil }
    score -= min(penaltyLength, 180)
    return max(score, 1)
  }

  private static func normalize(_ text: String, droppingApostrophes: Bool = false) -> String {
    var normalized = text
      .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
      .lowercased()
      .trimmingCharacters(in: .whitespacesAndNewlines)

    normalized.unicodeScalars.removeAll(where: { apostropheScalars.contains($0) && droppingApostrophes })

    let unifiedApostrophe = String(String.UnicodeScalarView(normalized.unicodeScalars.map { scalar in
      apostropheScalars.contains(scalar) ? "'" : scalar
    }))

    return unifiedApostrophe
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
  }

  private static func tokens(from text: String) -> [String] {
    var values: [String] = []
    var current = ""

    for scalar in text.unicodeScalars {
      if CharacterSet.alphanumerics.contains(scalar) || scalar == "'" {
        current.unicodeScalars.append(scalar)
      } else if current.isEmpty == false {
        values.append(current)
        current = ""
      }
    }

    if current.isEmpty == false {
      values.append(current)
    }

    return values
      .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "@#'")) }
      .filter { $0.isEmpty == false }
  }

  private static func isSubsequence(_ query: String, of text: String) -> Bool {
    guard query.isEmpty == false, text.isEmpty == false else { return false }

    var textIndex = text.startIndex
    for queryCharacter in query {
      while textIndex < text.endIndex, text[textIndex] != queryCharacter {
        text.formIndex(after: &textIndex)
      }
      if textIndex == text.endIndex {
        return false
      }
      text.formIndex(after: &textIndex)
    }
    return true
  }

  private static let apostropheScalars: Set<UnicodeScalar> = [
    "'",
    "\u{2019}",
    "\u{2018}",
    "\u{02BC}",
  ]
}
