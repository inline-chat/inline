import Foundation

public enum InlineSearchMatchTier: Int, Sendable, Hashable, Comparable {
  case fuzzy = 1
  case compact = 2
  case substring = 3
  case tokenPrefix = 4
  case fieldPrefix = 5
  case exact = 6

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

public struct InlineSearchPreparedQuery: Sendable, Hashable {
  public let raw: String
  public let normalized: String
  public let compact: String
  public let tokens: [String]
}

public struct InlineSearchField: Sendable, Hashable {
  public let value: String
  public let priority: Int

  public init(_ value: String?, priority: Int) {
    self.value = value ?? ""
    self.priority = priority
  }
}

public struct InlineSearchPreparedField: Sendable, Hashable {
  let normalized: String
  let compact: String
  let tokens: [String]
  let priority: Int
  let length: Int
}

public struct InlineSearchMatch: Sendable, Hashable {
  public let tier: InlineSearchMatchTier
  public let fieldPriority: Int
  public let position: Int
  public let fieldLength: Int

  public static func isBetter(_ lhs: Self, than rhs: Self) -> Bool {
    if lhs.tier != rhs.tier {
      return lhs.tier > rhs.tier
    }
    if lhs.fieldPriority != rhs.fieldPriority {
      return lhs.fieldPriority > rhs.fieldPriority
    }
    if lhs.position != rhs.position {
      return lhs.position < rhs.position
    }
    return lhs.fieldLength < rhs.fieldLength
  }
}

public enum InlineSearchMatcher {
  public static func prepare(_ query: String) -> InlineSearchPreparedQuery? {
    let normalized = normalize(query)
    let compactQuery = compact(normalized)
    guard compactQuery.isEmpty == false else { return nil }

    let tokens = normalized.split(separator: " ").map(String.init)
    return InlineSearchPreparedQuery(
      raw: query.trimmingCharacters(in: .whitespacesAndNewlines),
      normalized: normalized,
      compact: compactQuery,
      tokens: tokens.isEmpty ? [compactQuery] : tokens
    )
  }

  public static func prepareField(_ field: InlineSearchField) -> InlineSearchPreparedField? {
    let normalized = normalize(field.value)
    guard normalized.isEmpty == false else { return nil }
    return InlineSearchPreparedField(
      normalized: normalized,
      compact: compact(normalized),
      tokens: normalized.split(separator: " ").map(String.init),
      priority: field.priority,
      length: normalized.count
    )
  }

  public static func match(
    query: InlineSearchPreparedQuery,
    fields: [InlineSearchField]
  ) -> InlineSearchMatch? {
    match(query: query, preparedFields: fields.compactMap(prepareField))
  }

  public static func match(
    query: InlineSearchPreparedQuery,
    preparedFields: [InlineSearchPreparedField]
  ) -> InlineSearchMatch? {
    var best: InlineSearchMatch?

    for field in preparedFields {
      guard let candidate = match(query: query, field: field) else { continue }
      if let currentBest = best {
        if InlineSearchMatch.isBetter(candidate, than: currentBest) {
          best = candidate
        }
      } else {
        best = candidate
      }
    }

    return best
  }

  public static func normalize(_ text: String) -> String {
    let folded = text
      .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
      .lowercased()

    var result = ""
    var needsSeparator = false

    for scalar in folded.unicodeScalars {
      if CharacterSet.alphanumerics.contains(scalar) {
        if needsSeparator, result.isEmpty == false {
          result.append(" ")
        }
        result.unicodeScalars.append(scalar)
        needsSeparator = false
      } else if result.isEmpty == false {
        needsSeparator = true
      }
    }

    return result
  }

  public static func compact(_ text: String) -> String {
    String(String.UnicodeScalarView(text.unicodeScalars.filter {
      CharacterSet.alphanumerics.contains($0)
    }))
  }

  private static func match(
    query: InlineSearchPreparedQuery,
    field: InlineSearchPreparedField
  ) -> InlineSearchMatch? {
    if field.normalized == query.normalized {
      return result(.exact, field: field)
    }

    if field.normalized.hasPrefix(query.normalized) {
      return result(.fieldPrefix, field: field)
    }

    if let tokenIndex = matchingTokenIndex(query: query, field: field) {
      return result(.tokenPrefix, field: field, position: tokenIndex)
    }

    if let range = field.normalized.range(of: query.normalized) {
      return result(
        .substring,
        field: field,
        position: field.normalized.distance(from: field.normalized.startIndex, to: range.lowerBound)
      )
    }

    if query.compact.count >= 2,
       let compactPosition = compactMatchPosition(query: query.compact, field: field.compact) {
      return result(.compact, field: field, position: compactPosition)
    }

    guard query.compact.count >= 3 else { return nil }
    guard field.compact.count <= query.compact.count + 24 else { return nil }
    guard isSubsequence(query.compact, of: field.compact) else { return nil }
    return result(.fuzzy, field: field)
  }

  private static func matchingTokenIndex(
    query: InlineSearchPreparedQuery,
    field: InlineSearchPreparedField
  ) -> Int? {
    var earliestIndex: Int?

    for queryToken in query.tokens {
      guard let index = field.tokens.firstIndex(where: { $0.hasPrefix(queryToken) }) else {
        return nil
      }
      earliestIndex = min(earliestIndex ?? index, index)
    }

    return earliestIndex
  }

  private static func compactMatchPosition(query: String, field: String) -> Int? {
    guard let range = field.range(of: query) else { return nil }
    return field.distance(from: field.startIndex, to: range.lowerBound)
  }

  private static func result(
    _ tier: InlineSearchMatchTier,
    field: InlineSearchPreparedField,
    position: Int = 0
  ) -> InlineSearchMatch {
    InlineSearchMatch(
      tier: tier,
      fieldPriority: field.priority,
      position: position,
      fieldLength: field.length
    )
  }

  private static func isSubsequence(_ query: String, of field: String) -> Bool {
    var fieldIndex = field.startIndex

    for character in query {
      while fieldIndex < field.endIndex, field[fieldIndex] != character {
        field.formIndex(after: &fieldIndex)
      }
      guard fieldIndex < field.endIndex else { return false }
      field.formIndex(after: &fieldIndex)
    }

    return true
  }
}
