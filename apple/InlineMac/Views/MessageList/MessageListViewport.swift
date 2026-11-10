import AppKit

/// Geometry of the native clip at the instant a table mutation is applied.
@MainActor
struct MessageListViewport {
  let table: NSTableView
  let scroll: NSScrollView
  let rows: ChatRowListViewModel

  var distanceFromBottom: CGFloat {
    let bounds = scroll.contentView.bounds
    let insets = scroll.contentInsets
    if table.frame.height + insets.top + insets.bottom <= bounds.height { return 0 }
    return table.frame.height + insets.bottom - bounds.maxY
  }

  struct Anchor {
    let id: ChatRowListViewModel.Row
    let oldIndex: Int
    let offset: CGFloat

    func hasChangesAbove(_ indices: IndexSet) -> Bool {
      guard let first = indices.first else { return false }
      return first < oldIndex
    }
  }

  /// Keep candidates in reading order so a deletion can fall back to the next surviving row.
  func anchors() -> [Anchor] {
    let bounds = scroll.contentView.bounds
    let insets = scroll.contentInsets
    let height = bounds.height - insets.top - insets.bottom
    guard height > 0 else { return [] }
    let visible = NSRect(x: 0, y: bounds.minY + insets.top, width: table.bounds.width, height: height)
    let range = table.rows(in: visible)
    guard range.location != NSNotFound, range.length > 0 else { return [] }
    return (range.location ..< NSMaxRange(range)).compactMap { row in
      guard let id = rows.row(at: row) else { return nil }
      switch id {
        case .message, .parentMessage: break
        default: return nil
      }
      let rect = table.rect(ofRow: row)
      guard rect.maxY > visible.minY, rect.minY < visible.maxY else { return nil }
      return Anchor(id: id, oldIndex: row, offset: rect.minY - bounds.minY)
    }
  }

  func index(of anchor: Anchor) -> Int? {
    switch anchor.id {
      case let .message(id): rows.rowIndex(forMessageStableId: id)
      case .parentMessage: rows.row(at: 0) == anchor.id ? 0 : nil
      default: nil
    }
  }

  func restore(_ anchor: Anchor) {
    guard let row = index(of: anchor) else { return }
    let clip = scroll.contentView
    let rect = table.rect(ofRow: row)
    // If a large row collapsed past the passage being read, show its beginning.
    let topInset = scroll.contentInsets.top
    let offset = anchor.offset + rect.height <= topInset ? topInset : anchor.offset
    let target = rect.minY - offset
    // A mutation below the viewport should not even interrupt elastic scrolling.
    guard abs(target - clip.bounds.minY) >= 0.5 else { return }
    var proposed = clip.bounds
    proposed.origin.y = target
    clip.updateBounds(clip.constrainBoundsRect(proposed).origin, cancel: true)
  }
}
