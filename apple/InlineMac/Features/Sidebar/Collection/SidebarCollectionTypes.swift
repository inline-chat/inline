import AppKit
import InlineKit

/// Shared boundary between the SwiftUI sidebar orchestrator and collection
/// body. Keep these contracts independent of controller-specific drag and
/// layout machinery.
struct SidebarCollectionRow: Equatable, Identifiable {
  enum SectionHeader: String, CaseIterable, Hashable {
    case pinned
    case content

    func title(sidebarAsInbox: Bool, archiveVisible: Bool) -> String {
      switch self {
      case .pinned:
        "Pinned"
      case .content:
        archiveVisible ? "Archived" : (sidebarAsInbox ? "Open" : "Chats")
      }
    }
  }

  static let sectionHeaderHeight: CGFloat = 28
  static let sectionTopSpacing: CGFloat = 4
  static let spacedSectionHeaderHeight = sectionHeaderHeight + sectionTopSpacing
  static let emptyPinnedTargetHeight: CGFloat = 56
  static let itemVisualGap: CGFloat = 1
  static let itemVisualEdgeInset = itemVisualGap / 2

  static func paintedItemHeight(for rowHeight: CGFloat) -> CGFloat {
    max(rowHeight - itemVisualGap, 0)
  }

  enum ID: Hashable {
    case allChats
    case grid
    case archiveHeader
    case sectionHeader(SectionHeader)
    case pinDropGuide
    case chat(ChatListItem.Identifier)
    case newThread
    case emptyState
  }

  enum Kind: Equatable {
    case allChats
    case grid
    case archiveHeader
    case sectionHeader(SectionHeader, isExpanded: Bool)
    case pinDropGuide
    case chat(SidebarProjectedItem)
    case newThread
    case emptyState
  }

  let id: ID
  let kind: Kind
  let height: CGFloat

  var projectedItem: SidebarProjectedItem? {
    guard case let .chat(projectedItem) = kind else { return nil }
    return projectedItem
  }

  var isSectionHeader: Bool {
    guard case .sectionHeader = kind else { return false }
    return true
  }

  /// Interactive paint and hit testing belong to a full-width AppKit item;
  /// each SwiftUI row applies its own visual inset inside that stable boundary.
  var usesFullWidthCollectionLayout: Bool {
    switch id {
    case .allChats, .grid, .sectionHeader, .pinDropGuide, .chat, .newThread:
      true
    case .archiveHeader, .emptyState:
      false
    }
  }

  var sectionHeader: (section: SectionHeader, isExpanded: Bool)? {
    guard case let .sectionHeader(section, isExpanded) = kind else { return nil }
    return (section, isExpanded)
  }

  static func sectionHeader(
    _ section: SectionHeader,
    isExpanded: Bool,
    height: CGFloat = spacedSectionHeaderHeight
  ) -> Self {
    Self(
      id: .sectionHeader(section),
      kind: .sectionHeader(section, isExpanded: isExpanded),
      height: height
    )
  }

  static func pinDropGuide(height: CGFloat = 0) -> Self {
    Self(
      id: .pinDropGuide,
      kind: .pinDropGuide,
      height: height
    )
  }
}

struct SidebarCollectionScrollRequest: Equatable {
  let itemID: ChatListItem.Identifier
  let token: Int
}

struct SidebarCollectionRenderState: Equatable {
  struct Preview: Equatable {
    let itemSize: String
    let unreadBadgeStyle: String
    let colorScheme: String
    let themeRevision: Int
    let temporaryItemID: ChatListItem.Identifier?
  }

  let selectedPeer: Peer?
  let selectedReplyPeer: Peer?
  let allChatsSelected: Bool
  let gridSelectionKey: String
  let titlesDimmed: Bool
  let scopedProminentUnreadCount: Int
  let scopedOtherUnreadCount: Int
  let homeGridAvatarIDs: [Int64]
  let sidebarAsInbox: Bool
  let archiveVisible: Bool
  let externalDropTargetID: ChatListItem.Identifier?
  let preview: Preview
}

/// Narrow, collection-owned state needed while rendering one hosted row.
/// Keeping drag presentation out of the SwiftUI environment makes each reused
/// row an explicit projection of the controller's current scene.
struct SidebarCollectionRowRenderContext: Equatable {
  let dimsPinDropInstruction: Bool

  static let idle = Self(dimsPinDropInstruction: false)
}

struct SidebarCollectionMove {
  enum HierarchyChange: Equatable {
    case detach(ChatListItem.Identifier)
    case attach(ChatListItem.Identifier, parentID: ChatListItem.Identifier)
  }

  let targetItems: [SidebarViewModel.Item]
  let movedItem: SidebarViewModel.Item
  let sourceIsRoot: Bool
  let newIndex: Int
  let sourceLane: SidebarOrderLane
  let targetLane: SidebarOrderLane
  let hierarchyChange: HierarchyChange?
}

/// Immutable semantic destination captured while an external drag is hovering.
/// It deliberately contains everything needed to navigate and import after
/// mouse-up so a SwiftUI refresh or temporary-row replacement cannot retarget it.
struct SidebarCollectionExternalDropTarget: Hashable {
  let rowID: ChatListItem.Identifier
  let peer: Peer
  let parentPeer: Peer?
  let userID: Int64?
  let generation: UUID
}

struct SidebarCollectionActions {
  let move: (
    SidebarCollectionMove,
    @escaping @MainActor @Sendable (Bool) -> Void
  ) -> Void
  let toggleDisclosure: (ChatListItem.Identifier) -> Void
  let externalDropTarget: (
    ChatListItem.Identifier
  ) -> SidebarCollectionExternalDropTarget?
  let externalDropTargetChanged: (ChatListItem.Identifier?) -> Void
  let performExternalDrop: (SidebarCollectionExternalDropTarget, NSPasteboard) -> Bool
}
