import Foundation
import SwiftUI

enum SidebarOrderLane: String {
  case normal
  case pinned

  func order(for item: SidebarViewModel.Item?) -> String? {
    switch self {
    case .normal:
      item?.order
    case .pinned:
      item?.pinnedOrder
    }
  }
}

struct SidebarDragState: Equatable {
  let sourceLane: SidebarOrderLane
  let itemKey: String
  let sourceIndex: Int
  let startPointerOffset: CGPoint
  let sourceItemsByLane: [SidebarOrderLane: [SidebarViewModel.Item]]
  var targetLane: SidebarOrderLane
  var targetIndex: Int
  let startMouseY: CGFloat
  var itemsByLane: [SidebarOrderLane: [SidebarViewModel.Item]]
  var preview: SidebarDragPreviewState

  func items(for lane: SidebarOrderLane) -> [SidebarViewModel.Item]? {
    itemsByLane[lane]
  }

  func sourceItems(for lane: SidebarOrderLane) -> [SidebarViewModel.Item] {
    sourceItemsByLane[lane] ?? []
  }
}

struct SidebarOrderHold: Equatable {
  let id = UUID()
  let itemsByLane: [SidebarOrderLane: [SidebarViewModel.Item]]

  func items(for lane: SidebarOrderLane) -> [SidebarViewModel.Item]? {
    itemsByLane[lane]
  }
}

struct SidebarDragCommit: Equatable {
  let targetItems: [SidebarViewModel.Item]
  let movedItem: SidebarViewModel.Item
  let newIndex: Int
  let sourceLane: SidebarOrderLane
  let targetLane: SidebarOrderLane
}

struct SidebarDragPreviewState: Equatable {
  let item: SidebarViewModel.Item
  var rowSize: CGSize
  var origin: CGPoint
  var colorScheme: ColorScheme
}

enum SidebarReorderConstants {
  static let orderHoldDuration: Duration = .milliseconds(100)
}
