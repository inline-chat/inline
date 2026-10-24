import CoreGraphics
import Synchronization

/// Thread-safe cache of typeset text, bounded by the UTF-16 length it holds.
///
/// One huge message can't evict everything else: entries over a quarter of the budget are
/// returned but not stored.
public final class TextLayoutCache: Sendable {
  struct Key: Hashable {
    let text: MessageText
    let style: TextLayoutStyle
    let widthPixels: Int
    let scale: CGFloat
  }

  private struct State {
    var entries: [Key: (layout: TextLayout, stamp: UInt64)] = [:]
    var cost = 0
    var clock: UInt64 = 0
  }

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
    if let hit = state.withLock({ state -> TextLayout? in
      guard let entry = state.entries[key] else { return nil }
      state.clock += 1
      state.entries[key]?.stamp = state.clock
      return entry.layout
    }) {
      return hit
    }

    let layout = TextLayouter.layout(text, style: style, maximumWidth: maximumWidth, grid: grid)
    let cost = max(1, text.length)
    guard cost <= budget / 4 else { return layout }
    state.withLock { state in
      state.clock += 1
      if state.entries.updateValue((layout, state.clock), forKey: key) == nil {
        state.cost += cost
      }
      while state.cost > budget, let oldest = state.entries.min(by: { $0.value.stamp < $1.value.stamp }) {
        state.entries.removeValue(forKey: oldest.key)
        state.cost -= max(1, oldest.key.text.length)
      }
    }
    return layout
  }

  public func removeAll() {
    state.withLock { state in
      state.entries.removeAll()
      state.cost = 0
    }
  }

  var count: Int { state.withLock { $0.entries.count } }
}
