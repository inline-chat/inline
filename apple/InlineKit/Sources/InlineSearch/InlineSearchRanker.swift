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

  typealias PreparedQuery = InlineSearchPreparedQuery

  static func prepare(_ query: String) -> PreparedQuery? {
    InlineSearchMatcher.prepare(query)
  }

  static func score(query: PreparedQuery, fields: [Field]) -> Int? {
    let searchableFields = fields.map { field in
      InlineSearchField(field.text, priority: field.weight * 100)
    }
    guard let match = InlineSearchMatcher.match(query: query, fields: searchableFields) else {
      return nil
    }
    return match.tier.rawValue * 10_000 + match.fieldPriority - min(match.position, 500)
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
    InlineSearchMatcher.normalize(text)
  }

  static func compact(_ text: String) -> String {
    InlineSearchMatcher.compact(text)
  }
}
