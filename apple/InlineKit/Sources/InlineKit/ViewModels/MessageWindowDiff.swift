import Foundation

/// How a reloaded message window differs from the one on screen.
///
/// A reload rereads the whole window, but most reloads (a history refetch on open, sync catch-up)
/// return the rows already shown. Lists use this to skip the update or touch only the rows that
/// changed instead of rebuilding every visible cell.
public enum MessageWindowDiff: Equatable, Sendable {
  /// Same messages, same order, same content.
  case unchanged
  /// Same messages in the same order; these (stable ids) have new content.
  case updated(Set<Int64>)
  /// Every shown message is still there, unchanged and in the same order; these were added.
  case inserted(Set<Int64>)
  /// The remaining messages are unchanged and in the same order; these are gone.
  case removed(Set<Int64>)
  /// Anything else: reorders, or additions or removals together with edits.
  case replaced

  public init(from old: [FullMessage], to new: [FullMessage]) {
    if old.count == new.count, zip(old, new).allSatisfy({ $0.id == $1.id }) {
      var changed = Set<Int64>()
      for (lhs, rhs) in zip(old, new) where lhs != rhs {
        changed.insert(rhs.id)
      }
      self = changed.isEmpty ? .unchanged : .updated(changed)
      return
    }

    let oldIDs = Set(old.map(\.id))
    let newIDs = Set(new.map(\.id))
    if new.count > old.count, oldIDs.isSubset(of: newIDs),
       new.filter({ oldIDs.contains($0.id) }).elementsEqual(old)
    {
      self = .inserted(newIDs.subtracting(oldIDs))
      return
    }
    if new.count < old.count, newIDs.isSubset(of: oldIDs),
       old.filter({ newIDs.contains($0.id) }).elementsEqual(new)
    {
      self = .removed(oldIDs.subtracting(newIDs))
      return
    }
    self = .replaced
  }
}
