import CoreGraphics
import Foundation
import Synchronization

/// Thread-safe cache of typeset text, bounded by the UTF-16 length it holds.
///
/// One huge message can't evict everything else: entries over a quarter of the budget are
/// returned but not stored. The least recently used entry goes first. A streaming message
/// replaces its previous version instead of leaving one dead entry per edit.
public final class TextLayoutCache: Sendable {
  struct Key: Hashable {
    let text: MessageText
    let style: TextLayoutStyle
    let widthPixels: Int
    let scale: CGFloat

    /// True when `self` is a shorter version of `newer`'s text typeset the same way, which a
    /// streamed message leaves behind on each edit.
    func isEarlierVersion(of newer: Key) -> Bool {
      guard style == newer.style, widthPixels == newer.widthPixels, scale == newer.scale,
            text.length > 0, text.length < newer.text.length
      else { return false }
      let prefix = text.attributedString.string as NSString
      let string = newer.text.attributedString.string as NSString
      return string.compare(
        prefix as String,
        options: .literal,
        range: NSRange(location: 0, length: prefix.length)
      ) == .orderedSame
    }
  }

  /// An entry in the recency list. Nodes live in one array and link by index, so a hit or an
  /// eviction is O(1) and allocates nothing.
  private struct Node {
    var key: Key?
    var layout: TextLayout?
    var cost = 0
    /// Toward the least recently used end.
    var older = -1
    /// Toward the most recently used end.
    var newer = -1
  }

  private struct State {
    var slots: [Key: Int] = [:]
    var nodes: [Node] = []
    var free: [Int] = []
    var newest = -1
    var oldest = -1
    var cost = 0
    /// Keys stored most recently, newest last, checked for a streamed message's previous version.
    var recentInserts: [Key] = []

    mutating func unlink(_ slot: Int) {
      let older = nodes[slot].older
      let newer = nodes[slot].newer
      if newer >= 0 { nodes[newer].older = older } else { newest = older }
      if older >= 0 { nodes[older].newer = newer } else { oldest = newer }
      nodes[slot].older = -1
      nodes[slot].newer = -1
    }

    mutating func makeNewest(_ slot: Int) {
      nodes[slot].older = newest
      nodes[slot].newer = -1
      if newest >= 0 { nodes[newest].newer = slot } else { oldest = slot }
      newest = slot
    }

    mutating func touch(_ slot: Int) {
      guard newest != slot else { return }
      unlink(slot)
      makeNewest(slot)
    }

    mutating func remove(_ slot: Int) {
      unlink(slot)
      if let key = nodes[slot].key { slots.removeValue(forKey: key) }
      cost -= nodes[slot].cost
      // Drop the text and lines now rather than when the slot is reused.
      nodes[slot] = Node()
      free.append(slot)
    }

    mutating func insert(_ key: Key, layout: TextLayout, cost entryCost: Int, budget: Int) {
      if let slot = slots[key] {
        nodes[slot].layout = layout
        touch(slot)
        return
      }
      let slot: Int
      if let reused = free.popLast() {
        slot = reused
      } else {
        slot = nodes.count
        nodes.append(Node())
      }
      nodes[slot] = Node(key: key, layout: layout, cost: entryCost)
      slots[key] = slot
      makeNewest(slot)
      cost += entryCost
      while cost > budget, oldest >= 0, oldest != slot {
        remove(oldest)
      }
    }
  }

  /// How many recent insertions a new one is compared with: enough for the few texts one rich
  /// message typesets per edit.
  private static let recentInsertLimit = 8

  private let budget: Int
  private let state = Mutex(State())

  /// `characterBudget` caps the total text length kept; layouts cost roughly in proportion.
  public init(characterBudget: Int = 400_000) {
    budget = max(1, characterBudget)
  }

  public func layout(
    _ text: MessageText,
    style: TextLayoutStyle = .init(),
    maximumWidth: CGFloat,
    grid: PixelGrid
  ) -> TextLayout {
    let key = Key(
      text: text,
      style: style,
      widthPixels: Int((TextLayouter.clampedWidth(maximumWidth) * grid.scale).rounded(.down)),
      scale: grid.scale
    )
    let lookup = state.withLock { state -> (hit: TextLayout?, recent: [Key]) in
      guard let slot = state.slots[key] else { return (nil, state.recentInserts) }
      state.touch(slot)
      return (state.nodes[slot].layout, [])
    }
    if let hit = lookup.hit {
      return hit
    }

    let layout = TextLayouter.layout(text, style: style, maximumWidth: maximumWidth, grid: grid)
    // Compared outside the lock. Dropping an entry another thread still wants only costs it a
    // retypeset; results never depend on what the cache holds.
    let superseded = lookup.recent.filter { $0.isEarlierVersion(of: key) }
    let cost = max(1, text.length)
    let stores = cost <= budget / 4
    guard stores || !superseded.isEmpty else { return layout }
    state.withLock { state in
      for old in superseded {
        if let slot = state.slots[old] { state.remove(slot) }
      }
      if !superseded.isEmpty {
        state.recentInserts.removeAll { superseded.contains($0) }
      }
      guard stores else { return }
      state.insert(key, layout: layout, cost: cost, budget: budget)
      state.recentInserts.removeAll { $0 == key }
      state.recentInserts.append(key)
      if state.recentInserts.count > Self.recentInsertLimit {
        state.recentInserts.removeFirst()
      }
    }
    return layout
  }

  public func removeAll() {
    state.withLock { state in
      state = State()
    }
  }

  var count: Int { state.withLock { $0.slots.count } }
}
