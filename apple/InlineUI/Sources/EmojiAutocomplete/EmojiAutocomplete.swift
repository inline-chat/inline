import Foundation

public struct EmojiAutocompleteSuggestion: Hashable, Identifiable, Sendable {
  public let emoji: String
  public let shortcode: String
  public let label: String

  public var id: String {
    "\(emoji)-\(shortcode)"
  }

  public init(emoji: String, shortcode: String, label: String) {
    self.emoji = emoji
    self.shortcode = shortcode
    self.label = label
  }
}

struct EmojiAutocompleteEntry: Sendable {
  let emoji: String
  let shortcode: String
  let label: String
  let terms: [EmojiAutocompleteTerm]
  let words: [String]
}

struct EmojiAutocompleteTerm: Sendable {
  enum Kind: Int, Sendable {
    case shortcode
    case alias
    case keyword
    case compact
  }

  let value: String
  let kind: Kind
}

enum EmojiAutocompleteData {}

extension EmojiAutocompleteData {
  static let entries: [EmojiAutocompleteEntry] = parseEntries()
  static let index = EmojiAutocompleteIndex(entries: entries)

  private static func parseEntries() -> [EmojiAutocompleteEntry] {
    rawEntries.split(separator: "\n").map { line in
      let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
      precondition(parts.count == 3 || parts.count == 4, "Invalid emoji autocomplete row: \(line)")
      let shortcode = String(parts[1])
      let aliases = EmojiAutocompleteAliases.keywordsByShortcode[shortcode] ?? []
      let keywords = parts.count == 4 ? parts[3].split(separator: ",").map(String.init) : []
      let terms = makeTerms(shortcode: shortcode, aliases: aliases, keywords: keywords)

      return EmojiAutocompleteEntry(
        emoji: String(parts[0]),
        shortcode: shortcode,
        label: String(parts[2]),
        terms: terms,
        words: makeWords(terms: terms)
      )
    }
  }

  private static func makeTerms(shortcode: String, aliases: [String], keywords: [String]) -> [EmojiAutocompleteTerm] {
    var result: [EmojiAutocompleteTerm] = []
    var seen = Set<String>()

    func add(_ value: String, kind: EmojiAutocompleteTerm.Kind) {
      let normalized = EmojiAutocomplete.normalize(value)
      guard !normalized.isEmpty, seen.insert("\(kind.rawValue)-\(normalized)").inserted else { return }
      result.append(EmojiAutocompleteTerm(value: normalized, kind: kind))

      let compact = normalized.replacingOccurrences(of: "_", with: "")
      if compact != normalized, compact.count >= 3, seen.insert("\(EmojiAutocompleteTerm.Kind.compact.rawValue)-\(compact)").inserted {
        result.append(EmojiAutocompleteTerm(value: compact, kind: .compact))
      }
    }

    add(shortcode, kind: .shortcode)
    aliases.forEach { add($0, kind: .alias) }
    keywords.forEach { add($0, kind: .keyword) }

    return result
  }

  private static func makeWords(terms: [EmojiAutocompleteTerm]) -> [String] {
    var seen = Set<String>()
    return terms
      .flatMap { term -> [String] in
        var values = term.value.split(separator: "_").map(String.init)
        values.append(term.value)
        return values
      }
      .filter { $0.count > 1 && seen.insert($0).inserted }
      .sorted()
  }
}

struct EmojiAutocompleteIndex: Sendable {
  private let candidateIndexesByFirstScalar: [UnicodeScalar: [Int]]

  init(entries: [EmojiAutocompleteEntry]) {
    var indexes: [UnicodeScalar: [Int]] = [:]

    for (index, entry) in entries.enumerated() {
      var seenScalars = Set<UnicodeScalar>()
      for term in entry.terms {
        guard let scalar = term.value.unicodeScalars.first, seenScalars.insert(scalar).inserted else {
          continue
        }
        indexes[scalar, default: []].append(index)
      }

      for word in entry.words {
        guard let scalar = word.unicodeScalars.first, seenScalars.insert(scalar).inserted else {
          continue
        }
        indexes[scalar, default: []].append(index)
      }
    }

    candidateIndexesByFirstScalar = indexes
  }

  func candidates(for query: String) -> [EmojiAutocompleteEntry] {
    guard let scalar = query.unicodeScalars.first,
          let indexes = candidateIndexesByFirstScalar[scalar]
    else {
      return []
    }

    return indexes.map { EmojiAutocompleteData.entries[$0] }
  }
}

enum EmojiAutocompleteAliases {
  static let keywordsByShortcode: [String: [String]] = [
    "joy": ["lol", "lmao", "lmfao", "roflmao", "haha", "hahaha", "hehe", "laugh", "laughing", "funny", "dying"],
    "rofl": ["lol", "lmao", "lmfao", "roflmao", "rotfl", "haha", "hahaha", "laugh", "laughing", "funny"],
    "laughing": ["lol", "xd", "x_d", "haha", "hahaha", "hehe", "happy", "laugh", "laughing"],
    "smile": ["happy", "smiley"],
    "slight_smile": ["happy"],
    "sob": ["cry", "sad", "bawling"],
    "cry": ["sad", "tear", "tears"],
    "skull": ["dead", "ded", "rip", "dying", "im_dead", "deadass"],
    "headstone": ["rip", "grave", "graveyard", "tombstone"],
    "fire": ["lit", "hot"],
    "100": ["hundred", "perfect", "facts", "real"],
    "tada": ["party", "celebrate", "celebration"],
    "partying_face": ["party", "celebrate", "celebration", "birthday", "bday"],
    "rocket": ["launch", "ship"],
    "thumbsup": ["+1", "like", "approve", "yes"],
    "thumbsdown": ["-1", "dislike", "no"],
    "white_check_mark": ["done", "complete", "yes"],
    "x": ["wrong"],
    "face_with_open_mouth": ["o"],
    "red_heart": ["heart", "love"],
    "heart": ["love"],
    "eyes": ["look", "looking", "watching", "seen"],
    "pleading_face": ["please", "pls", "puppy", "puppy_eyes", "beg"],
    "thinking": ["hmm", "hmmm", "think"],
    "face_with_raised_eyebrow": ["sus", "suspicious", "skeptic"],
    "roll_eyes": ["eyeroll", "eye_roll", "whatever"],
    "face_with_hand_over_mouth": ["oops", "whoops"],
    "exploding_head": ["mindblown", "mind_blown", "omg", "wtf", "shocked"],
    "scream": ["omg", "scared", "shock", "shocked", "fear"],
    "wave": ["hi", "hello", "hey", "bye"],
    "clap": ["applause", "bravo"],
    "raised_hands": ["hooray", "yay", "celebrate"],
    "pray": ["please", "pls", "thanks", "thank_you", "highfive", "high_five"],
    "prohibited": ["no"],
    "person_gesturing_no": ["no"],
    "man_gesturing_no": ["no"],
    "woman_gesturing_no": ["no"],
    "person_facepalming": ["facepalm"],
    "person_shrugging": ["shrug", "idk"],
    "flag_united_kingdom": ["uk", "flag_uk"],
    "flag_norway": ["no"],
  ]
}

private struct EmojiAutocompleteMatch: Sendable {
  let rank: Int
  let wordsUsed: Int
  let length: Int
}

public enum EmojiAutocomplete {
  public static let allSuggestions: [EmojiAutocompleteSuggestion] = EmojiAutocompleteData.entries.map { entry in
    EmojiAutocompleteSuggestion(
      emoji: entry.emoji,
      shortcode: entry.shortcode,
      label: entry.label
    )
  }

  public static func suggestions(matching query: String, limit: Int = 8) -> [EmojiAutocompleteSuggestion] {
    let query = normalize(query)
    guard !query.isEmpty, limit > 0 else { return [] }

    return EmojiAutocompleteData.index.candidates(for: query).enumerated()
      .compactMap { index, entry -> (match: EmojiAutocompleteMatch, shortcodeLength: Int, index: Int, suggestion: EmojiAutocompleteSuggestion)? in
        guard let match = match(entry, query: query) else { return nil }

        return (
          match,
          entry.shortcode.count,
          index,
          EmojiAutocompleteSuggestion(
            emoji: entry.emoji,
            shortcode: entry.shortcode,
            label: entry.label
          )
        )
      }
      .sorted {
        if $0.match.rank != $1.match.rank { return $0.match.rank < $1.match.rank }
        if $0.match.wordsUsed != $1.match.wordsUsed { return $0.match.wordsUsed < $1.match.wordsUsed }
        if $0.match.length != $1.match.length { return $0.match.length < $1.match.length }
        if $0.shortcodeLength != $1.shortcodeLength { return $0.shortcodeLength < $1.shortcodeLength }
        return $0.index < $1.index
      }
      .prefix(limit)
      .map(\.suggestion)
  }

  static func normalize(_ value: String) -> String {
    let folded = value.folding(
      options: [.caseInsensitive, .diacriticInsensitive],
      locale: Locale(identifier: "en_US_POSIX")
    )
    var result = ""
    var previousWasSeparator = false

    let scalars = Array(folded.lowercased().unicodeScalars)
    for (index, scalar) in scalars.enumerated() {
      if CharacterSet.alphanumerics.contains(scalar) {
        result.unicodeScalars.append(scalar)
        previousWasSeparator = false
      } else if scalar == "+" || scalar == "-" {
        if index + 1 == scalars.count || CharacterSet.decimalDigits.contains(scalars[index + 1]) {
          result.unicodeScalars.append(scalar)
          previousWasSeparator = false
        }
      } else if scalar == "_" || scalar == " " {
        guard !result.isEmpty, !previousWasSeparator else { continue }
        result.append("_")
        previousWasSeparator = true
      }
    }

    return result.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
  }

  private static func match(_ entry: EmojiAutocompleteEntry, query: String) -> EmojiAutocompleteMatch? {
    if query.count < 3 {
      return exactMatch(entry, query: query)
    }

    if let exact = exactMatch(entry, query: query) {
      return exact
    }

    if let prefix = entry.terms
      .lazy
      .filter({ $0.value.hasPrefix(query) })
      .map({ EmojiAutocompleteMatch(rank: prefixRank(for: $0.kind), wordsUsed: 1, length: $0.value.count) })
      .min(by: isBetterMatch)
    {
      return prefix
    }

    if let wordsUsed = wordsUsedToMatch(query: query, words: entry.words) {
      return EmojiAutocompleteMatch(rank: 8 + min(wordsUsed, 4), wordsUsed: wordsUsed, length: entry.shortcode.count)
    }

    return nil
  }

  private static func exactMatch(_ entry: EmojiAutocompleteEntry, query: String) -> EmojiAutocompleteMatch? {
    entry.terms
      .lazy
      .filter { $0.value == query }
      .filter { query.count > 1 || $0.kind == .shortcode || $0.kind == .alias }
      .map { EmojiAutocompleteMatch(rank: exactRank(for: $0.kind), wordsUsed: 1, length: $0.value.count) }
      .min(by: isBetterMatch)
  }

  private static func exactRank(for kind: EmojiAutocompleteTerm.Kind) -> Int {
    switch kind {
    case .shortcode: 0
    case .alias: 1
    case .keyword: 2
    case .compact: 3
    }
  }

  private static func prefixRank(for kind: EmojiAutocompleteTerm.Kind) -> Int {
    switch kind {
    case .shortcode: 4
    case .alias: 5
    case .keyword: 6
    case .compact: 7
    }
  }

  private static func isBetterMatch(_ lhs: EmojiAutocompleteMatch, _ rhs: EmojiAutocompleteMatch) -> Bool {
    if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
    if lhs.wordsUsed != rhs.wordsUsed { return lhs.wordsUsed < rhs.wordsUsed }
    return lhs.length < rhs.length
  }

  private static func wordsUsedToMatch(query: String, words: [String]) -> Int? {
    guard !words.isEmpty else { return nil }

    var used = Set<Int>()
    return matchTail(
      query: Array(query),
      position: 0,
      words: words,
      used: &used,
      wordsUsed: 0,
      best: nil
    )
  }

  private static func matchTail(
    query: [Character],
    position: Int,
    words: [String],
    used: inout Set<Int>,
    wordsUsed: Int,
    best: Int?
  ) -> Int? {
    if position == query.count {
      return min(best ?? wordsUsed, wordsUsed)
    }

    if let best, wordsUsed >= best {
      return best
    }

    guard wordsUsed < 4 else { return best }

    var best = best
    for (index, word) in words.enumerated() {
      guard !used.contains(index), word.first == query[position] else { continue }

      used.insert(index)
      let commonCount = commonPrefixCount(query: query, position: position, word: word)
      if commonCount > 0 {
        for count in stride(from: commonCount, through: 1, by: -1) {
          best = matchTail(
            query: query,
            position: position + count,
            words: words,
            used: &used,
            wordsUsed: wordsUsed + 1,
            best: best
          )
        }
      }
      used.remove(index)
    }

    return best
  }

  private static func commonPrefixCount(query: [Character], position: Int, word: String) -> Int {
    var count = 0
    for (queryChar, wordChar) in zip(query.dropFirst(position), word) {
      guard queryChar == wordChar else { break }
      count += 1
    }
    return count
  }
}
