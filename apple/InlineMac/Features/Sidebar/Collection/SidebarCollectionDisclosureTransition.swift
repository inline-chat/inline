import AppKit
import InlineKit
import InlineMacSidebarModel
import QuartzCore

struct SidebarCollectionDisclosureDescriptor {
  private struct Change {
    let rowID: SidebarCollectionRow.ID
    let owner: Owner
    let wasExpanded: Bool
    let isExpanded: Bool
  }

  enum Owner: Equatable {
    case section(SidebarCollectionRow.SectionHeader)
    case chat(ChatListItem.Identifier)
    case folder(Int64)
  }

  let owner: Owner
  let identity: SidebarCollectionDisclosurePlan<SidebarCollectionRow.ID>
  let expandedPresentation: SidebarBodyPresentation
  let collapsedPresentation: SidebarBodyPresentation
  let targetProgress: CGFloat

  var ownerID: SidebarCollectionRow.ID { identity.ownerID }

  static func make(
    from previous: SidebarBodyPresentation,
    to next: SidebarBodyPresentation
  ) -> Self? {
    let commonIDs = Set(previous.orderedIDs).intersection(next.orderedIDs)
    let changes = commonIDs.compactMap { rowID -> Change? in
      guard let oldRow = previous.rowByID[rowID],
            let newRow = next.rowByID[rowID],
            let oldState = disclosureState(for: oldRow),
            let newState = disclosureState(for: newRow),
            oldState.owner == newState.owner,
            oldState.isExpanded != newState.isExpanded
      else { return nil }
      return Change(
        rowID: rowID,
        owner: oldState.owner,
        wasExpanded: oldState.isExpanded,
        isExpanded: newState.isExpanded
      )
    }
    guard changes.count == 1, let change = changes.first else { return nil }

    let expandedPresentation = change.wasExpanded ? previous : next
    let collapsedPresentation = change.wasExpanded ? next : previous
    guard let identity = SidebarCollectionDisclosurePlan(
      expandedIDs: expandedPresentation.orderedIDs,
      collapsedIDs: collapsedPresentation.orderedIDs,
      ownerID: change.rowID
    ), validatesAffectedRows(
      identity.affectedIDs,
      owner: change.owner,
      in: expandedPresentation
    ), commonGeometryMatches(
      expanded: expandedPresentation,
      collapsed: collapsedPresentation
    ) else { return nil }

    return Self(
      owner: change.owner,
      identity: identity,
      expandedPresentation: expandedPresentation,
      collapsedPresentation: collapsedPresentation,
      targetProgress: change.isExpanded ? 1 : 0
    )
  }

  func liveExpandedPresentation(
    merging target: SidebarBodyPresentation
  ) -> SidebarBodyPresentation {
    SidebarBodyPresentation(
      generation: target.generation,
      rows: expandedPresentation.rows.map { target.rowByID[$0.id] ?? $0 },
      renderState: target.renderState
    )
  }

  private static func disclosureState(
    for row: SidebarCollectionRow
  ) -> (owner: Owner, isExpanded: Bool)? {
    if let sectionHeader = row.sectionHeader {
      return (.section(sectionHeader.section), sectionHeader.isExpanded)
    }
    if let folder = row.projectedFolder {
      return (.folder(folder.id), folder.isExpanded)
    }
    guard let item = row.projectedItem, item.isExpandable else { return nil }
    return (.chat(item.id), item.isExpanded)
  }

  private static func validatesAffectedRows(
    _ affectedIDs: [SidebarCollectionRow.ID],
    owner: Owner,
    in expanded: SidebarBodyPresentation
  ) -> Bool {
    switch owner {
    case let .chat(ownerID):
      guard let ownerDepth = expanded.rowByID[.chat(ownerID)]?.presentationDepth else {
        return false
      }
      return affectedIDs.allSatisfy { rowID in
        guard let depth = expanded.rowByID[rowID]?.presentationDepth else { return false }
        return depth > ownerDepth
      }
    case let .folder(ownerID):
      guard let ownerDepth = expanded.rowByID[.folder(ownerID)]?.presentationDepth else {
        return false
      }
      return affectedIDs.allSatisfy { rowID in
        guard let depth = expanded.rowByID[rowID]?.presentationDepth else { return false }
        return depth > ownerDepth
      }
    case let .section(section):
      return affectedIDs.allSatisfy { rowID in
        guard let row = expanded.rowByID[rowID] else { return false }
        switch (section, row.kind) {
        case (.pinned, let .chat(item)):
          return item.lane == .pinned
        case (.content, let .chat(item)):
          return item.lane == .normal
        case (.content, let .folder(folder)):
          return folder.lane == .normal
        case (.content, .folderNewThread):
          return true
        case (.content, .newThread):
          return true
        case (.content, .emptyState):
          return true
        default:
          return false
        }
      }
    }
  }

  private static func commonGeometryMatches(
    expanded: SidebarBodyPresentation,
    collapsed: SidebarBodyPresentation
  ) -> Bool {
    collapsed.rows.allSatisfy { collapsedRow in
      guard let expandedRow = expanded.rowByID[collapsedRow.id] else { return false }
      return abs(expandedRow.height - collapsedRow.height) <= 0.5
        && expandedRow.presentationLane == collapsedRow.presentationLane
    }
  }
}

struct SidebarCollectionDisclosureGeometry: Equatable {
  let affectedIDs: Set<SidebarCollectionRow.ID>
  let trailingIDs: Set<SidebarCollectionRow.ID>
  let expandedFrames: [SidebarCollectionRow.ID: CGRect]
  let groupTopY: CGFloat
  let height: CGFloat

  func layoutState(hidesAffectedRows: Bool = false) -> SidebarBodyLayoutDisclosure {
    SidebarBodyLayoutDisclosure(
      affectedIDs: affectedIDs,
      trailingIDs: trailingIDs,
      collapsedOffsetY: -height,
      hidesAffectedRows: hidesAffectedRows
    )
  }
}

@MainActor
final class SidebarCollectionDisclosureAnimator {
  private let clockLayer = CALayer()
  private var geometry: SidebarCollectionDisclosureGeometry?
  private var collectionView: NSCollectionView?
  private var modelProgress: CGFloat = 1
  private var animationToken = UUID()

  var progress: CGFloat {
    CGFloat(clockLayer.presentation()?.opacity ?? Float(modelProgress))
  }

  func install(in collectionView: NSCollectionView) {
    self.collectionView = collectionView
    collectionView.wantsLayer = true
    clockLayer.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
    clockLayer.backgroundColor = NSColor.clear.cgColor
    clockLayer.opacity = Float(modelProgress)
    collectionView.layer?.addSublayer(clockLayer)
  }

  func begin(
    geometry: SidebarCollectionDisclosureGeometry,
    initialProgress: CGFloat,
    targetProgress: CGFloat,
    completion: @escaping @MainActor @Sendable (UUID) -> Void
  ) -> UUID {
    reset()
    self.geometry = geometry
    modelProgress = clamped(initialProgress)
    let targetProgress = clamped(targetProgress)
    setClockProgress(modelProgress)
    applyPresentation(progress: modelProgress)
    return animate(to: targetProgress, completion: completion)
  }

  func retarget(
    to progress: CGFloat,
    completion: @escaping @MainActor @Sendable (UUID) -> Void
  ) -> UUID {
    let currentProgress = self.progress
    stopAnimations(at: currentProgress)
    let targetProgress = clamped(progress)
    return animate(to: targetProgress, completion: completion)
  }

  func reset() {
    animationToken = UUID()
    clockLayer.removeAllAnimations()
    setClockProgress(modelProgress)
    guard let collectionView else {
      geometry = nil
      return
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for case let item as SidebarCollectionBodyItem in collectionView.visibleItems() {
      item.clearDisclosurePresentation()
    }
    CATransaction.commit()
    geometry = nil
  }

  private func animate(
    to target: CGFloat,
    completion: @escaping @MainActor @Sendable (UUID) -> Void
  ) -> UUID {
    let start = modelProgress
    let distance = abs(target - start)
    animationToken = UUID()
    let token = animationToken
    guard distance > 0.001 else {
      applyPresentation(progress: target)
      modelProgress = target
      setClockProgress(target)
      Task { @MainActor in completion(token) }
      return token
    }

    // Preserve enough time for a reversal to decelerate cleanly. Linear
    // distance scaling made a half-finished reversal complete in one rigid
    // 80 ms snap; square-root scaling stays quick without throwing velocity
    // away at the next click.
    let duration = max(
      SidebarDisclosureMotion.minimumRetargetDuration,
      SidebarDisclosureMotion.duration * sqrt(Double(distance))
    )
    let timing = CAMediaTimingFunction(
      controlPoints: Float(SidebarDisclosureMotion.controlPoint1.x),
      Float(SidebarDisclosureMotion.controlPoint1.y),
      Float(SidebarDisclosureMotion.controlPoint2.x),
      Float(SidebarDisclosureMotion.controlPoint2.y)
    )
    let beginTime = CACurrentMediaTime()
    CATransaction.begin()
    CATransaction.setCompletionBlock {
      Task { @MainActor in completion(token) }
    }
    animateClock(
      from: start,
      to: target,
      duration: duration,
      beginTime: beginTime,
      timing: timing
    )
    animateVisibleItems(
      from: start,
      to: target,
      duration: duration,
      beginTime: beginTime,
      timing: timing
    )
    CATransaction.commit()
    modelProgress = target
    return token
  }

  private func animateClock(
    from start: CGFloat,
    to target: CGFloat,
    duration: TimeInterval,
    beginTime: CFTimeInterval,
    timing: CAMediaTimingFunction
  ) {
    CATransaction.setDisableActions(true)
    clockLayer.opacity = Float(target)
    let animation = CABasicAnimation(keyPath: "opacity")
    animation.fromValue = Float(start)
    animation.toValue = Float(target)
    animation.beginTime = beginTime
    animation.duration = duration
    animation.timingFunction = timing
    clockLayer.add(animation, forKey: "sidebar-disclosure-clock")
  }

  private func animateVisibleItems(
    from start: CGFloat,
    to target: CGFloat,
    duration: TimeInterval,
    beginTime: CFTimeInterval,
    timing: CAMediaTimingFunction
  ) {
    guard let geometry, let collectionView else { return }
    for case let item as SidebarCollectionBodyItem in collectionView.visibleItems() {
      guard let rowID = item.representedRowID,
            let expandedFrame = geometry.expandedFrames[rowID],
            let layer = item.view.layer
      else { continue }

      if geometry.affectedIDs.contains(rowID) {
        let mask = disclosureMask(for: layer)
        let targetPath = clipPath(
          item: item,
          expandedFrame: expandedFrame,
          progress: target,
          geometry: geometry
        )
        CATransaction.setDisableActions(true)
        mask.path = targetPath
        let animation = disclosureClipAnimation(
          item: item,
          expandedFrame: expandedFrame,
          from: start,
          to: target,
          geometry: geometry
        )
        animation.beginTime = beginTime
        animation.duration = duration
        animation.timingFunction = timing
        mask.add(animation, forKey: "sidebar-disclosure-clip")
      }

      if geometry.trailingIDs.contains(rowID) {
        let startTransform = transform(progress: start, height: geometry.height)
        let targetTransform = transform(progress: target, height: geometry.height)
        CATransaction.setDisableActions(true)
        layer.transform = targetTransform
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: startTransform)
        animation.toValue = NSValue(caTransform3D: targetTransform)
        animation.beginTime = beginTime
        animation.duration = duration
        animation.timingFunction = timing
        layer.add(animation, forKey: "sidebar-disclosure-tail")
      }
    }
  }

  private func disclosureClipAnimation(
    item: SidebarCollectionBodyItem,
    expandedFrame: CGRect,
    from start: CGFloat,
    to target: CGFloat,
    geometry: SidebarCollectionDisclosureGeometry
  ) -> CAKeyframeAnimation {
    let rowStart = (expandedFrame.minY - geometry.groupTopY) / geometry.height
    let rowEnd = (expandedFrame.maxY - geometry.groupTopY) / geometry.height
    let progresses = SidebarCollectionDisclosureTimeline.keyProgresses(
      from: Double(start),
      to: Double(target),
      rowStart: Double(rowStart),
      rowEnd: Double(rowEnd)
    )
    let distance = target - start
    let animation = CAKeyframeAnimation(keyPath: "path")
    animation.values = progresses.map { progress in
      clipPath(
        item: item,
        expandedFrame: expandedFrame,
        progress: CGFloat(progress),
        geometry: geometry
      )
    }
    animation.keyTimes = progresses.map { progress in
      NSNumber(value: Double((CGFloat(progress) - start) / distance))
    }
    animation.calculationMode = .linear
    return animation
  }

  private func stopAnimations(at progress: CGFloat) {
    clockLayer.removeAllAnimations()
    modelProgress = clamped(progress)
    setClockProgress(modelProgress)
    guard let collectionView else { return }
    for case let item as SidebarCollectionBodyItem in collectionView.visibleItems() {
      guard let rowID = item.representedRowID,
            let geometry,
            let expandedFrame = geometry.expandedFrames[rowID],
            let layer = item.view.layer
      else { continue }
      layer.removeAnimation(forKey: "sidebar-disclosure-tail")
      layer.mask?.removeAnimation(forKey: "sidebar-disclosure-clip")
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      if geometry.affectedIDs.contains(rowID) {
        disclosureMask(for: layer).path = clipPath(
          item: item,
          expandedFrame: expandedFrame,
          progress: modelProgress,
          geometry: geometry
        )
      }
      if geometry.trailingIDs.contains(rowID) {
        layer.transform = transform(progress: modelProgress, height: geometry.height)
      }
      CATransaction.commit()
    }
  }

  private func applyPresentation(progress: CGFloat) {
    guard let geometry, let collectionView else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for case let item as SidebarCollectionBodyItem in collectionView.visibleItems() {
      guard let rowID = item.representedRowID,
            let expandedFrame = geometry.expandedFrames[rowID],
            let layer = item.view.layer
      else { continue }
      if geometry.affectedIDs.contains(rowID) {
        disclosureMask(for: layer).path = clipPath(
          item: item,
          expandedFrame: expandedFrame,
          progress: progress,
          geometry: geometry
        )
      }
      if geometry.trailingIDs.contains(rowID) {
        layer.transform = transform(progress: progress, height: geometry.height)
      }
    }
    CATransaction.commit()
  }

  private func disclosureMask(for layer: CALayer) -> CAShapeLayer {
    if let mask = layer.mask as? CAShapeLayer, mask.name == "SidebarDisclosureMask" {
      mask.frame = layer.bounds
      return mask
    }
    let mask = CAShapeLayer()
    mask.name = "SidebarDisclosureMask"
    mask.frame = layer.bounds
    mask.fillColor = NSColor.black.cgColor
    mask.contentsScale = layer.contentsScale
    layer.mask = mask
    return mask
  }

  private func clipPath(
    item: SidebarCollectionBodyItem,
    expandedFrame: CGRect,
    progress: CGFloat,
    geometry: SidebarCollectionDisclosureGeometry
  ) -> CGPath {
    let rowStart = (expandedFrame.minY - geometry.groupTopY) / geometry.height
    let rowEnd = (expandedFrame.maxY - geometry.groupTopY) / geometry.height
    let visibleFraction = SidebarCollectionDisclosureTimeline.visibleFraction(
      progress: Double(clamped(progress)),
      rowStart: Double(rowStart),
      rowEnd: Double(rowEnd)
    )
    let visibleHeight = expandedFrame.height * CGFloat(visibleFraction)
    let bounds = item.view.bounds
    // The mask is evaluated in the unflipped backing-layer coordinate space,
    // even though the collection's document view is flipped. Visual top is
    // therefore maxY in this local layer. Anchoring at minY makes expansion
    // reveal bottom-to-top and leaves the bottom fragment during collapse.
    let visibleRect = CGRect(
      x: bounds.minX,
      y: bounds.maxY - visibleHeight,
      width: bounds.width,
      height: visibleHeight
    )
    return CGPath(rect: visibleRect, transform: nil)
  }

  private func transform(progress: CGFloat, height: CGFloat) -> CATransform3D {
    CATransform3DMakeTranslation(0, height * clamped(progress), 0)
  }

  private func setClockProgress(_ progress: CGFloat) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    clockLayer.opacity = Float(clamped(progress))
    CATransaction.commit()
  }

  private func clamped(_ progress: CGFloat) -> CGFloat {
    min(max(progress, 0), 1)
  }
}
