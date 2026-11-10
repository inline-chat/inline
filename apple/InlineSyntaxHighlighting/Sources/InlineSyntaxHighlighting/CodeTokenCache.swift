import Foundation
import Synchronization

/// Process-wide LRU of computed tokens, bounded by the total UTF-16 length of
/// the cached sources. Lookups are synchronous so views can color code on
/// their first frame.
final class CodeTokenCache: Sendable {
  struct Key: Hashable, Sendable {
    let text: String
    let language: CodeSyntaxHighlighter.LanguageKind
    private let utf8Count: Int
    private let hash: Int

    init(text: String, language: CodeSyntaxHighlighter.LanguageKind) {
      // Bridged strings are made native once so hashing and comparing can
      // use raw bytes.
      var text = text
      text.makeContiguousUTF8()
      var hasher = Hasher()
      hasher.combine(language)
      // Hash the literal bytes, not the String: canonically equivalent sources
      // compare equal as Strings but have different UTF-16 token offsets.
      text.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
      self.text = text
      self.language = language
      utf8Count = text.utf8.count
      hash = hasher.finalize()
    }

    // Uses the hash computed once at init, so dictionary growth does not
    // rehash every cached source.
    func hash(into hasher: inout Hasher) {
      hasher.combine(hash)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
      guard lhs.hash == rhs.hash, lhs.utf8Count == rhs.utf8Count, lhs.language == rhs.language else {
        return false
      }
      var left = lhs.text
      var right = rhs.text
      return left.withUTF8 { leftBytes in
        right.withUTF8 { rightBytes in
          leftBytes.count == rightBytes.count
            && (leftBytes.isEmpty || memcmp(leftBytes.baseAddress!, rightBytes.baseAddress!, leftBytes.count) == 0)
        }
      }
    }
  }

  private struct Entry {
    let tokens: [CodeToken]
    let cost: Int
    var stamp: UInt64
  }

  private struct State {
    var entries: [Key: Entry] = [:]
    // Recency log; an item is stale when its stamp no longer matches the
    // entry's. Popping stale items keeps eviction amortized O(1).
    var recency: [(key: Key, stamp: UInt64)] = []
    var recencyHead = 0
    var stamp: UInt64 = 0
    var totalCost = 0
  }

  let costLimit: Int
  private let state = Mutex(State())

  init(costLimit: Int) {
    self.costLimit = costLimit
  }

  func tokens(for text: String, language: CodeSyntaxHighlighter.LanguageKind) -> [CodeToken]? {
    let key = Key(text: text, language: language)
    return state.withLock { state in
      guard var entry = state.entries[key] else { return nil }
      state.stamp &+= 1
      entry.stamp = state.stamp
      state.entries[key] = entry
      Self.recordUse(of: key, in: &state)
      return entry.tokens
    }
  }

  func insert(_ tokens: [CodeToken], for text: String, language: CodeSyntaxHighlighter.LanguageKind) {
    let cost = max(1, text.utf16.count)
    guard cost <= costLimit else { return }
    let key = Key(text: text, language: language)
    state.withLock { state in
      state.stamp &+= 1
      let previous = state.entries.updateValue(.init(tokens: tokens, cost: cost, stamp: state.stamp), forKey: key)
      state.totalCost += cost - (previous?.cost ?? 0)
      Self.recordUse(of: key, in: &state)
      while state.totalCost > costLimit, state.recencyHead < state.recency.count {
        let oldest = state.recency[state.recencyHead]
        state.recencyHead += 1
        guard let entry = state.entries[oldest.key], entry.stamp == oldest.stamp else { continue }
        state.entries[oldest.key] = nil
        state.totalCost -= entry.cost
      }
      Self.compactRecencyIfNeeded(&state)
    }
  }

  var totalCost: Int {
    state.withLock { $0.totalCost }
  }

  var count: Int {
    state.withLock { $0.entries.count }
  }

  private static func recordUse(of key: Key, in state: inout State) {
    state.recency.append((key, state.stamp))
    compactRecencyIfNeeded(&state)
  }

  /// Drops consumed and stale log items once they outnumber live entries, so
  /// repeated hits do not grow the log without bound.
  private static func compactRecencyIfNeeded(_ state: inout State) {
    let pending = state.recency.count - state.recencyHead
    guard pending > state.entries.count * 2 + 64 || state.recencyHead > 1_024 else { return }
    let entries = state.entries
    state.recency = state.recency[state.recencyHead...].filter { item in
      entries[item.key]?.stamp == item.stamp
    }
    state.recencyHead = 0
  }
}
