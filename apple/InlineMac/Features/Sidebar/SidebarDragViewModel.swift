import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class SidebarDragViewModel {
  private var state: SidebarDragState?
  private var hold: SidebarOrderHold?

  @ObservationIgnored private var holdTask: Task<Void, Never>?
  @ObservationIgnored private var eventMonitor: Any?
  @ObservationIgnored private var commitHandler: ((SidebarDragCommit) -> Void)?
  @ObservationIgnored private let previewWindow = SidebarDragPreviewWindow.shared

  var animationKey: String {
    let dragKey = state.map { state in
      let pinned = state.items(for: .pinned)?.map(Self.itemKey).joined(separator: ",") ?? ""
      let normal = state.items(for: .normal)?.map(Self.itemKey).joined(separator: ",") ?? ""
      return "drag:\(state.sourceLane.rawValue):\(state.targetLane.rawValue):\(state.targetIndex):\(pinned)|\(normal)"
    } ?? ""
    let holdKey = hold.map { hold in
      let pinned = hold.items(for: .pinned)?.map(Self.itemKey).joined(separator: ",") ?? ""
      let normal = hold.items(for: .normal)?.map(Self.itemKey).joined(separator: ",") ?? ""
      return "hold:\(hold.id):\(pinned)|\(normal)"
    } ?? ""

    return "\(dragKey)|\(holdKey)"
  }

  func displayItems(
    _ items: [SidebarViewModel.Item],
    lane: SidebarOrderLane?
  ) -> [SidebarViewModel.Item] {
    guard let lane else { return items }
    if let stateItems = state?.items(for: lane) {
      return stateItems
    }
    if let holdItems = hold?.items(for: lane) {
      return holdItems
    }
    return items
  }

  func isDragging(
    _ item: SidebarViewModel.Item,
    lane: SidebarOrderLane?
  ) -> Bool {
    guard let lane, let state else { return false }
    let key = Self.itemKey(item)
    return state.itemKey == key && state.items(for: lane)?.contains(where: { Self.itemKey($0) == key }) == true
  }

  func dragChanged(
    item: SidebarViewModel.Item,
    lane: SidebarOrderLane,
    sourceItems: [SidebarViewModel.Item],
    pinnedItems: [SidebarViewModel.Item],
    normalItems: [SidebarViewModel.Item],
    value: DragGesture.Value,
    rowSize: CGSize,
    rowHeight: CGFloat,
    colorScheme: ColorScheme,
    commit: @escaping (SidebarDragCommit) -> Void
  ) {
    let key = Self.itemKey(item)
    let measuredSize = CGSize(
      width: max(rowSize.width, 1),
      height: max(rowSize.height, rowHeight)
    )
    let location = NSEvent.mouseLocation
    let previewOrigin = CGPoint(
      x: location.x - value.startLocation.x,
      y: location.y - (measuredSize.height - value.startLocation.y)
    )

    guard let state else {
      startDrag(
        item: item,
        itemKey: key,
        lane: lane,
        sourceItems: sourceItems,
        pinnedItems: pinnedItems,
        normalItems: normalItems,
        measuredSize: measuredSize,
        pointerOffset: value.startLocation,
        previewOrigin: previewOrigin,
        colorScheme: colorScheme,
        locationY: location.y,
        commit: commit
      )
      return
    }

    guard state.itemKey == key else { return }
    updateDrag(
      state: state,
      location: location,
      rowSize: measuredSize,
      colorScheme: colorScheme
    )
  }

  func dragEnded() -> SidebarDragCommit? {
    finishDrag()
  }

  func cancel() {
    holdTask?.cancel()
    holdTask = nil
    state = nil
    hold = nil
    commitHandler = nil
    removeEventMonitor()
    previewWindow.hide()
  }

  private func updateDrag(
    state: SidebarDragState,
    location: CGPoint,
    rowSize: CGSize,
    colorScheme: ColorScheme
  ) {
    var state = state
    let placement = targetPlacement(locationY: location.y, state: state, rowHeight: rowSize.height)
    let targetChanged = placement.lane != state.targetLane || placement.index != state.targetIndex
    state.targetLane = placement.lane
    state.targetIndex = placement.index
    state.itemsByLane = reorderedItemsByLane(
      item: state.preview.item,
      itemKey: state.itemKey,
      pinnedItems: state.sourceItems(for: .pinned),
      normalItems: state.sourceItems(for: .normal),
      targetLane: placement.lane,
      targetIndex: placement.index
    )
    state.preview.origin = previewOrigin(location: location, rowSize: rowSize, pointerOffset: state.startPointerOffset)
    state.preview.rowSize = rowSize
    state.preview.colorScheme = colorScheme
    previewWindow.update(state: state.preview)

    if targetChanged {
      withAnimation(.smoothSnappy) {
        self.state = state
      }
    } else {
      self.state = state
    }
  }

  private func finishDrag() -> SidebarDragCommit? {
    guard let state else { return nil }
    previewWindow.hide()
    removeEventMonitor()
    commitHandler = nil
    self.state = nil

    guard state.sourceLane != state.targetLane || state.sourceIndex != state.targetIndex else {
      return nil
    }
    let movedItem = state.preview.item
    guard let targetItems = state.items(for: state.targetLane) else { return nil }
    guard let newIndex = targetItems.firstIndex(where: { Self.itemKey($0) == state.itemKey }) else {
      return nil
    }

    withAnimation(.smoothSnappy) {
      holdOrder(state.itemsByLane)
    }

    return SidebarDragCommit(
      targetItems: targetItems,
      movedItem: movedItem,
      newIndex: newIndex,
      sourceLane: state.sourceLane,
      targetLane: state.targetLane
    )
  }

  private func startDrag(
    item: SidebarViewModel.Item,
    itemKey: String,
    lane: SidebarOrderLane,
    sourceItems: [SidebarViewModel.Item],
    pinnedItems: [SidebarViewModel.Item],
    normalItems: [SidebarViewModel.Item],
    measuredSize: CGSize,
    pointerOffset: CGPoint,
    previewOrigin: CGPoint,
    colorScheme: ColorScheme,
    locationY: CGFloat,
    commit: @escaping (SidebarDragCommit) -> Void
  ) {
    holdTask?.cancel()
    holdTask = nil
    hold = nil

    guard let sourceIndex = sourceItems.firstIndex(where: { Self.itemKey($0) == itemKey }) else {
      return
    }
    commitHandler = commit

    let sourceItemsByLane: [SidebarOrderLane: [SidebarViewModel.Item]] = [
      .pinned: pinnedItems,
      .normal: normalItems,
    ]
    let itemsByLane = reorderedItemsByLane(
      item: item,
      itemKey: itemKey,
      pinnedItems: sourceItemsByLane[.pinned] ?? [],
      normalItems: sourceItemsByLane[.normal] ?? [],
      targetLane: lane,
      targetIndex: sourceIndex
    )
    let preview = SidebarDragPreviewState(
      item: item,
      rowSize: measuredSize,
      origin: previewOrigin,
      colorScheme: colorScheme
    )
    let state = SidebarDragState(
      sourceLane: lane,
      itemKey: itemKey,
      sourceIndex: sourceIndex,
      startPointerOffset: pointerOffset,
      sourceItemsByLane: sourceItemsByLane,
      targetLane: lane,
      targetIndex: sourceIndex,
      startMouseY: locationY,
      itemsByLane: itemsByLane,
      preview: preview
    )

    self.state = state
    previewWindow.show(state: preview)
    installEventMonitor()
  }

  private func holdOrder(_ itemsByLane: [SidebarOrderLane: [SidebarViewModel.Item]]) {
    let hold = SidebarOrderHold(itemsByLane: itemsByLane)
    holdTask?.cancel()
    self.hold = hold
    holdTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: SidebarReorderConstants.orderHoldDuration)
      } catch {
        return
      }

      guard let self, self.hold?.id == hold.id else { return }
      withAnimation(.smoothSnappy) {
        self.hold = nil
      }
      self.holdTask = nil
    }
  }

  private func targetPlacement(
    locationY: CGFloat,
    state: SidebarDragState,
    rowHeight: CGFloat
  ) -> (lane: SidebarOrderLane, index: Int) {
    let delta = Int(((locationY - state.startMouseY) / rowHeight).rounded())

    switch state.sourceLane {
    case .pinned:
      let pinnedCount = state.sourceItems(for: .pinned).count
      let normalCount = state.sourceItems(for: .normal).filter { Self.itemKey($0) != state.itemKey }.count
      let rawIndex = state.sourceIndex - delta
      if rawIndex < pinnedCount {
        return (.pinned, min(max(rawIndex, 0), max(pinnedCount - 1, 0)))
      }
      return (.normal, min(max(rawIndex - pinnedCount, 0), normalCount))

    case .normal:
      let pinnedCount = state.sourceItems(for: .pinned).filter { Self.itemKey($0) != state.itemKey }.count
      let normalCount = state.sourceItems(for: .normal).count
      let rawIndex = state.sourceIndex - delta
      if rawIndex >= 0 {
        return (.normal, min(rawIndex, max(normalCount - 1, 0)))
      }
      return (.pinned, min(max(pinnedCount + rawIndex + 1, 0), pinnedCount))
    }
  }

  private func reorderedItemsByLane(
    item: SidebarViewModel.Item,
    itemKey: String,
    pinnedItems: [SidebarViewModel.Item],
    normalItems: [SidebarViewModel.Item],
    targetLane: SidebarOrderLane,
    targetIndex: Int
  ) -> [SidebarOrderLane: [SidebarViewModel.Item]] {
    var pinned = pinnedItems.filter { Self.itemKey($0) != itemKey }
    var normal = normalItems.filter { Self.itemKey($0) != itemKey }

    switch targetLane {
    case .pinned:
      pinned.insert(item, at: min(max(targetIndex, 0), pinned.count))
    case .normal:
      normal.insert(item, at: min(max(targetIndex, 0), normal.count))
    }

    return [
      .pinned: pinned,
      .normal: normal,
    ]
  }

  static func itemKey(_ item: SidebarViewModel.Item) -> String {
    "\(item.id.kind.rawValue):\(item.id.rawValue)"
  }

  private func previewOrigin(location: CGPoint, rowSize: CGSize, pointerOffset: CGPoint) -> CGPoint {
    CGPoint(
      x: location.x - pointerOffset.x,
      y: location.y - (rowSize.height - pointerOffset.y)
    )
  }

  private func installEventMonitor() {
    removeEventMonitor()
    eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
      MainActor.assumeIsolated {
        self?.handleEvent(event)
      }
      return event
    }
  }

  private func removeEventMonitor() {
    guard let eventMonitor else { return }
    NSEvent.removeMonitor(eventMonitor)
    self.eventMonitor = nil
  }

  private func handleEvent(_ event: NSEvent) {
    guard let state else { return }

    switch event.type {
    case .leftMouseDragged:
      updateDrag(
        state: state,
        location: NSEvent.mouseLocation,
        rowSize: state.preview.rowSize,
        colorScheme: state.preview.colorScheme
      )
    case .leftMouseUp:
      let handler = commitHandler
      if let commit = finishDrag() {
        handler?(commit)
      }
    default:
      break
    }
  }
}
