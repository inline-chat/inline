import Foundation

public struct MessageSelectionState: Equatable, Sendable {
  public private(set) var isActive: Bool
  public private(set) var selectedStableIds: Set<Int64>
  public private(set) var anchorStableId: Int64?

  public var count: Int {
    selectedStableIds.count
  }

  public var isEmpty: Bool {
    selectedStableIds.isEmpty
  }

  public init() {
    isActive = false
    selectedStableIds = []
    anchorStableId = nil
  }

  public func isSelected(_ stableId: Int64) -> Bool {
    selectedStableIds.contains(stableId)
  }

  public func orderedSelection(in orderedIds: [Int64]) -> [Int64] {
    orderedIds.filter { selectedStableIds.contains($0) }
  }

  @discardableResult
  public mutating func begin(with stableId: Int64) -> Set<Int64> {
    selectOnly(stableId)
  }

  @discardableResult
  public mutating func clear() -> Set<Int64> {
    let changed = selectedStableIds
    isActive = false
    selectedStableIds.removeAll()
    anchorStableId = nil
    return changed
  }

  @discardableResult
  public mutating func selectOnly(_ stableId: Int64) -> Set<Int64> {
    let old = selectedStableIds
    isActive = true
    selectedStableIds = [stableId]
    anchorStableId = stableId
    return old.symmetricDifference(selectedStableIds)
  }

  @discardableResult
  public mutating func toggle(_ stableId: Int64, orderedIds: [Int64]) -> Set<Int64> {
    let old = selectedStableIds

    if selectedStableIds.contains(stableId) {
      selectedStableIds.remove(stableId)
    } else {
      selectedStableIds.insert(stableId)
    }

    normalize(orderedIds: orderedIds, fallbackStableId: stableId)
    return old.symmetricDifference(selectedStableIds)
  }

  @discardableResult
  public mutating func selectRange(to stableId: Int64, orderedIds: [Int64]) -> Set<Int64> {
    let old = selectedStableIds

    guard
      let anchorStableId,
      let anchorIndex = orderedIds.firstIndex(of: anchorStableId),
      let targetIndex = orderedIds.firstIndex(of: stableId)
    else {
      isActive = true
      selectedStableIds = [stableId]
      anchorStableId = stableId
      return old.symmetricDifference(selectedStableIds)
    }

    let lower = min(anchorIndex, targetIndex)
    let upper = max(anchorIndex, targetIndex)

    isActive = true
    selectedStableIds = Set(orderedIds[lower ... upper])
    self.anchorStableId = anchorStableId
    return old.symmetricDifference(selectedStableIds)
  }

  @discardableResult
  public mutating func selectAll(_ orderedIds: [Int64]) -> Set<Int64> {
    let old = selectedStableIds
    selectedStableIds = Set(orderedIds)
    normalize(orderedIds: orderedIds)
    return old.symmetricDifference(selectedStableIds)
  }

  @discardableResult
  public mutating func prune(validIds: Set<Int64>, orderedIds: [Int64]) -> Set<Int64> {
    let old = selectedStableIds
    selectedStableIds.formIntersection(validIds)
    normalize(orderedIds: orderedIds)
    return old.symmetricDifference(selectedStableIds)
  }

  private mutating func normalize(
    orderedIds: [Int64],
    fallbackStableId: Int64? = nil
  ) {
    guard !selectedStableIds.isEmpty else {
      isActive = false
      anchorStableId = nil
      return
    }

    isActive = true

    if let anchorStableId, selectedStableIds.contains(anchorStableId) {
      return
    }

    if let fallbackStableId, selectedStableIds.contains(fallbackStableId) {
      anchorStableId = fallbackStableId
      return
    }

    anchorStableId = orderedIds.first { selectedStableIds.contains($0) } ?? selectedStableIds.first
  }
}
