import Foundation

enum InlineSearchRanker {
  struct Field: Sendable {
    let text: String?
    let weight: Int

    init(_ text: String?, weight: Int = 1) {
      self.text = text
      self.weight = max(1, weight)
    }
  }

  struct PreparedQuery: Sendable, Equatable {
    let raw: String
    let normalized: String
    let compact: String
    let tokens: [String]
  }

  static func prepare(_ query: String) -> PreparedQuery? {
    let raw = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalized = normalize(raw)
    let compactQuery = compact(normalized)
    guard compactQuery.isEmpty == false else { return nil }

    let tokens = normalized
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .map(String.init)
      .filter { compact($0).isEmpty == false }

    return PreparedQuery(
      raw: raw,
      normalized: normalized,
      compact: compactQuery,
      tokens: tokens.isEmpty ? [normalized] : tokens
    )
  }

  static func score(query: PreparedQuery, fields: [Field]) -> Int? {
    var best = 0
    var tokenMatches = Set<String>()

    for field in fields {
      guard let value = field.text else { continue }
      let normalized = normalize(value)
      guard normalized.isEmpty == false else { continue }

      let compactValue = compact(normalized)
      let fieldScore = scoreField(
        normalized,
        compactValue: compactValue,
        query: query
      )

      if fieldScore > 0 {
        best = max(best, fieldScore * field.weight)
      }

      for token in query.tokens where normalized.contains(token) || compactValue.contains(compact(token)) {
        tokenMatches.insert(token)
      }
    }

    if tokenMatches.count == query.tokens.count {
      best = max(best, 260)
    }

    return best > 0 ? best : nil
  }

  static func activityScore(messageCount: Int, lastDate: Date, now: Date = Date()) -> Int {
    let countScore = min(180, Int(log2(Double(max(0, messageCount) + 1)) * 28))

    guard lastDate > Date.distantPast else {
      return countScore
    }

    let ageDays = max(0, now.timeIntervalSince(lastDate) / 86_400)
    let recencyScore: Int
    switch ageDays {
    case 0..<1:
      recencyScore = 120
    case 1..<7:
      recencyScore = 95
    case 7..<30:
      recencyScore = 70
    case 30..<180:
      recencyScore = 40
    default:
      recencyScore = 15
    }

    return countScore + recencyScore
  }

  static func normalize(_ text: String) -> String {
    text
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .lowercased()
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func compact(_ text: String) -> String {
    String(String.UnicodeScalarView(text.unicodeScalars.filter {
      CharacterSet.alphanumerics.contains($0)
    }))
  }

  private static func scoreField(
    _ value: String,
    compactValue: String,
    query: PreparedQuery
  ) -> Int {
    if value == query.normalized {
      return 1_000
    }

    if compactValue == query.compact {
      return 940
    }

    if value.hasPrefix(query.normalized) {
      return 820
    }

    if startsWithWord(value, query: query.normalized) {
      return 700
    }

    if value.contains(query.normalized) {
      return 520
    }

    if compactValue.contains(query.compact) {
      return 430
    }

    let matchedTokens = query.tokens.filter { token in
      value.contains(token) || compactValue.contains(compact(token))
    }

    guard matchedTokens.isEmpty == false else { return 0 }
    return matchedTokens.count == query.tokens.count ? 360 : 140
  }

  private static func startsWithWord(_ value: String, query: String) -> Bool {
    value
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .contains { $0.hasPrefix(query) }
  }
}
