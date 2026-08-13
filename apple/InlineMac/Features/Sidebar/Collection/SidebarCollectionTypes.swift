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
        archiveVisible ? "Archived" : (sidebarAsInbox ? "Inbox" : "Chats")
      }
    }
  }

  static let sectionHeaderHeight: CGFloat = 36
  static let pinDropGuideHeight: CGFloat = 76

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

  var sectionHeader: (section: SectionHeader, isExpanded: Bool)? {
    guard case let .sectionHeader(section, isExpanded) = kind else { return nil }
    return (section, isExpanded)
  }

  static func sectionHeader(_ section: SectionHeader, isExpanded: Bool) -> Self {
    Self(
      id: .sectionHeader(section),
      kind: .sectionHeader(section, isExpanded: isExpanded),
      height: sectionHeaderHeight
    )
  }

  static func pinDropGuide() -> Self {
    Self(
      id: .pinDropGuide,
      kind: .pinDropGuide,
      height: pinDropGuideHeight
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

/// Chat visibility at one collection viewport position. Boundary IDs keep
/// unread navigation meaningful in very short windows where only structural
/// rows intersect the viewport.
struct SidebarCollectionVisibleChatState: Equatable {
  let visibleIDs: Set<ChatListItem.Identifier>
  let lastIDAboveViewport: ChatListItem.Identifier?
  let firstIDBelowViewport: ChatListItem.Identifier?
}

struct SidebarCollectionActions {
  let visibleChatStateChanged: (SidebarCollectionVisibleChatState) -> Void
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
