/// Where each row is in the row list, by id.
///
/// A `[ID: Int]` built in this module runs as unspecialized generic code for the host's ID type (the module boundary
/// stops specialization): about 200 ns a row, 2 ms for 10,000 rows on every update that carries rows. This keys a
/// concrete `[Int: Int]` by the ids' hash values instead (one generic call a row, the hash), checks the row on
/// lookup, and keeps positions relative to an offset so that appends (arrivals) and prepends (history pages) update it
/// in O(added) after an O(n) comparison of ids.
public struct TimelineRowIndex<ID: Hashable & Sendable>: Sendable {
  private var rows: [ID] = []
  /// Hash value → stored position of the first row with it (position = stored + offset).
  private var first: [Int: Int] = [:]
  /// Hash value → stored positions of later rows sharing it (distinct ids colliding, rare).
  private var more: [Int: [Int]] = [:]
  private var offset = 0

  public init() {}

  public init(_ rows: [ID]) {
    rebuild(rows)
  }

  public var count: Int { rows.count }

  public subscript(id: ID) -> Int? {
    let hash = id.hashValue
    guard let stored = first[hash] else { return nil }
    if let position = check(stored, id) { return position }
    guard let others = more[hash] else { return nil }
    for stored in others {
      if let position = check(stored, id) { return position }
    }
    return nil
  }

  private func check(_ stored: Int, _ id: ID) -> Int? {
    let position = stored + offset
    guard position >= 0, position < rows.count, rows[position] == id else { return nil }
    return position
  }

  /// Takes the new row list: added at the end or at the start in O(added) once the old rows are found in place,
  /// rebuilt otherwise.
  public mutating func update(_ newRows: [ID]) {
    let old = rows
    let added = newRows.count - old.count
    if !old.isEmpty, added >= 0 {
      if Self.matches(newRows, at: 0, old) {
        rows = newRows
        for position in old.count ..< newRows.count { insert(newRows[position], stored: position - offset) }
        return
      }
      if added > 0, Self.matches(newRows, at: added, old) {
        rows = newRows
        offset += added
        for position in 0 ..< added { insert(newRows[position], stored: position - offset) }
        return
      }
    }
    rebuild(newRows)
  }

  private mutating func rebuild(_ newRows: [ID]) {
    rows = newRows
    offset = 0
    first = Dictionary(minimumCapacity: newRows.count)
    more = [:]
    for (position, id) in newRows.enumerated() { insert(id, stored: position) }
  }

  private mutating func insert(_ id: ID, stored: Int) {
    let hash = id.hashValue
    if let existing = first.updateValue(stored, forKey: hash) {
      first[hash] = existing
      more[hash, default: []].append(stored)
    }
  }

  /// Whether `old` appears in `rows` starting at `start`.
  private static func matches(_ rows: [ID], at start: Int, _ old: [ID]) -> Bool {
    guard start + old.count <= rows.count else { return false }
    // The ends first: a change usually shows there.
    guard rows[start] == old[0], rows[start + old.count - 1] == old[old.count - 1] else { return false }
    for i in 0 ..< old.count where rows[start + i] != old[i] { return false }
    return true
  }
}
