import Foundation

/// The change from one row snapshot to the next, by row id and row revision.
///
/// Usable three ways: a diffable data source applies the new snapshot's ids and
/// reconfigures `updates`; an `NSTableView` removes `removals` (old indices),
/// inserts `insertions` (new indices), moves `moves` and reloads `updates` (new
/// indices); ChatList's `apply` takes the whole new snapshot and uses
/// `insertions`/`removals` to choose row transitions. A refresh whose content
/// is unchanged is empty.
///
/// Cost: O(n + m) for ids and revisions plus Myers' difference on the id
/// sequences, O((n + m) · d) for d changed positions.
public struct ChatRowDiff: Equatable, Sendable {
  public struct Change: Equatable, Sendable {
    public let id: ChatRowID
    /// Old index for removals, new index for insertions.
    public let index: Int
  }

  public struct Move: Equatable, Sendable {
    public let id: ChatRowID
    public let from: Int
    public let to: Int
  }

  /// Rows that left, with their old indices, ascending. Excludes moved rows.
  public var removals: [Change]
  /// Rows that arrived, with their new indices, ascending. Excludes moved rows.
  public var insertions: [Change]
  /// Rows present in both whose relative order changed.
  public var moves: [Move]
  /// Rows present in both whose revision changed (content changed), with their
  /// old and new indices. A row can also appear in `moves`.
  public var updates: [Move]

  public var isEmpty: Bool { removals.isEmpty && insertions.isEmpty && moves.isEmpty && updates.isEmpty }

  public init(removals: [Change] = [], insertions: [Change] = [], moves: [Move] = [], updates: [Move] = []) {
    self.removals = removals
    self.insertions = insertions
    self.moves = moves
    self.updates = updates
  }

  /// From `old` (nil: nothing shown yet) to `new`.
  public init(from old: ChatRowSnapshot?, to new: ChatRowSnapshot) {
    guard let old else {
      self.init(insertions: new.rows.enumerated().map { Change(id: $0.element.id, index: $0.offset) })
      return
    }
    var removals: [Change] = []
    var insertions: [Change] = []
    var moves: [Move] = []
    let oldIDs = old.ids
    let newIDs = new.ids
    if oldIDs != newIDs {
      let difference = newIDs.difference(from: oldIDs).inferringMoves()
      for change in difference {
        switch change {
          case let .remove(offset, id, associatedWith):
            if associatedWith == nil { removals.append(Change(id: id, index: offset)) }
          case let .insert(offset, id, associatedWith):
            if let from = associatedWith {
              moves.append(Move(id: id, from: from, to: offset))
            } else {
              insertions.append(Change(id: id, index: offset))
            }
        }
      }
    }
    var updates: [Move] = []
    for (newIndex, row) in new.rows.enumerated() {
      guard let oldIndex = old.index(of: row.id), old.rows[oldIndex].revision != row.revision else { continue }
      updates.append(Move(id: row.id, from: oldIndex, to: newIndex))
    }
    self.init(
      removals: removals.sorted { $0.index < $1.index },
      insertions: insertions.sorted { $0.index < $1.index },
      moves: moves.sorted { $0.to < $1.to },
      updates: updates
    )
  }
}
