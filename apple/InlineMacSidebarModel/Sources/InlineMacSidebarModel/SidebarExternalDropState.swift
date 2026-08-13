/// Collection-owned external-drop targeting keyed by the AppKit drag sequence.
/// Reusable cells never own or deliver this state.
public struct SidebarExternalDropState<
  SequenceID: Hashable & Sendable,
  TargetID: Hashable & Sendable
>: Equatable, Sendable {
  public private(set) var sequenceID: SequenceID?
  public private(set) var hoveredTargetID: TargetID?

  public init() {}

  /// Returns true only when the visible target changed.
  @discardableResult
  public mutating func updateHover(
    sequenceID: SequenceID,
    targetID: TargetID?
  ) -> Bool {
    let changed = self.sequenceID != sequenceID || hoveredTargetID != targetID
    self.sequenceID = sequenceID
    hoveredTargetID = targetID
    return changed
  }

  /// Captures and clears the accepted target. Later reuse, selection, and
  /// snapshot updates cannot replace the returned semantic identity.
  public mutating func accept(sequenceID: SequenceID) -> TargetID? {
    accept(sequenceID: sequenceID) { _ in true }
  }

  /// Captures and clears the target only when it still belongs to the current
  /// presentation. Validation may reject disappearance but must never resolve
  /// a different semantic destination.
  public mutating func accept(
    sequenceID: SequenceID,
    validating isValid: (TargetID) -> Bool
  ) -> TargetID? {
    guard self.sequenceID == sequenceID else { return nil }
    let targetID = hoveredTargetID
    self.sequenceID = nil
    hoveredTargetID = nil
    guard let targetID, isValid(targetID) else { return nil }
    return targetID
  }

  /// Returns true only when the active target was cleared. A stale exit from
  /// an older drag sequence cannot clear a newer hover.
  @discardableResult
  public mutating func end(sequenceID: SequenceID? = nil) -> Bool {
    if let sequenceID, let activeSequence = self.sequenceID,
       sequenceID != activeSequence {
      return false
    }
    let changed = self.sequenceID != nil || hoveredTargetID != nil
    self.sequenceID = nil
    hoveredTargetID = nil
    return changed
  }
}
