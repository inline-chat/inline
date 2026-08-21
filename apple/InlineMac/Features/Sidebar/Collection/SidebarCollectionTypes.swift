import AppKit
import InlineKit

enum SidebarCollectionRowRenderer: String, Equatable {
  case swiftUI
  case appKit
}

struct SidebarPresentationConfiguration: Equatable {
  enum NewThreadPlacement: Equatable {
    case beforeContent
    case afterContent
    case hidden
  }

  struct SectionHeaders: Equatable {
    var pinned: Bool
    var content: Bool

    static let visible = Self(pinned: true, content: true)
    static let hidden = Self(pinned: false, content: false)
  }

  var sectionHeaders: SectionHeaders
  var newThreadPlacement: NewThreadPlacement
  var nesting: SidebarCollectionNestingPolicy

  static func inbox(openPlacement: DialogOpenPlacement) -> Self {
    Self(
      sectionHeaders: .visible,
      newThreadPlacement: openPlacement == .top ? .beforeContent : .afterContent,
      nesting: .inbox
    )
  }

  static let allChats = Self(
    sectionHeaders: .visible,
    newThreadPlacement: .beforeContent,
    nesting: .flat
  )

  static let archived = Self(
    sectionHeaders: .visible,
    newThreadPlacement: .hidden,
    nesting: .flat
  )
}

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
  static let timelineHeaderHeight: CGFloat = 28
  static let sectionTopSpacing: CGFloat = 8
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
    case timelineHeader(ChatListTimelinePeriod)
    case pinDropGuide
    case chat(ChatListItem.Identifier)
    case folder(Int64)
    case newThread
    case emptyState
  }

  enum Kind: Equatable {
    case allChats
    case grid
    case archiveHeader
    case sectionHeader(SectionHeader, isExpanded: Bool)
    case timelineHeader(ChatListTimelinePeriod)
    case pinDropGuide
    case chat(SidebarProjectedItem)
    case folder(SidebarProjectedFolder)
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

  var projectedFolder: SidebarProjectedFolder? {
    guard case let .folder(folder) = kind else { return nil }
    return folder
  }

  var projectedNodeID: SidebarCollectionNodeID? {
    switch kind {
    case let .chat(item): item.nodeID
    case let .folder(folder): folder.nodeID
    default: nil
    }
  }

  var presentationParentID: SidebarCollectionNodeID? {
    projectedItem?.parentID
  }

  var presentationDepth: Int? {
    switch kind {
    case let .chat(item): item.depth
    case let .folder(folder): folder.depth
    default: nil
    }
  }

  var presentationLane: SidebarOrderLane? {
    switch kind {
    case let .chat(item): item.lane
    case let .folder(folder): folder.lane
    default: nil
    }
  }

  var isSectionHeader: Bool {
    guard case .sectionHeader = kind else { return false }
    return true
  }

  var isTimelineHeader: Bool {
    guard case .timelineHeader = kind else { return false }
    return true
  }

  /// Interactive paint and hit testing belong to a full-width AppKit item;
  /// each SwiftUI row applies its own visual inset inside that stable boundary.
  var usesFullWidthCollectionLayout: Bool {
    switch id {
    case .allChats, .grid, .sectionHeader, .timelineHeader, .pinDropGuide, .chat, .folder,
         .newThread:
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

  static func timelineRows(
    _ items: [SidebarProjectedItem],
    chatRowHeight: CGFloat,
    relativeTo now: Date = Date(),
    calendar: Calendar = .autoupdatingCurrent
  ) -> [Self] {
    var rows: [Self] = []
    var currentPeriod: ChatListTimelinePeriod?

    for item in items {
      let period = ChatListTimelinePeriod.classify(
        item.item.lastActivityAt,
        relativeTo: now,
        calendar: calendar
      )
      if currentPeriod != period {
        rows.append(Self(
          id: .timelineHeader(period),
          kind: .timelineHeader(period),
          height: timelineHeaderHeight
        ))
        currentPeriod = period
      }
      rows.append(Self(
        id: .chat(item.id),
        kind: .chat(item),
        height: chatRowHeight
      ))
    }

    return rows
  }
}

struct SidebarCollectionScrollRequest: Equatable {
  let itemID: ChatListItem.Identifier
  let token: Int
}

struct SidebarCollectionRenderState: Equatable {
  struct Preview: Equatable {
    let renderer: SidebarCollectionRowRenderer
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
  let forceHoverAppearance: Bool
  let disclosureExpandedOverride: Bool?
  let suppressesAnimations: Bool

  static let idle = Self(
    dimsPinDropInstruction: false,
    forceHoverAppearance: false,
    disclosureExpandedOverride: nil,
    suppressesAnimations: false
  )
  static let dragPreview = Self(
    dimsPinDropInstruction: false,
    forceHoverAppearance: true,
    disclosureExpandedOverride: nil,
    suppressesAnimations: true
  )
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
  let hasPreviousOrder: Bool
  let previousOrder: String?
  let hasNextOrder: Bool
  let nextOrder: String?
  let sourceLane: SidebarOrderLane
  let targetLane: SidebarOrderLane
  let hierarchyChange: HierarchyChange?
  /// `nil` keeps current folder membership. Root/folder values are persisted
  /// by the same atomic dialog-order RPC as the fractional order.
  let dialogDestination: DialogOrderDestination?
}

struct SidebarCollectionFolderMove {
  let folder: SidebarViewModel.Folder
  let newIndex: Int
  let hasPreviousOrder: Bool
  let previousOrder: String?
  let hasNextOrder: Bool
  let nextOrder: String?
}

enum SidebarCollectionMoveIntent {
  case chat(SidebarCollectionMove)
  case folder(SidebarCollectionFolderMove)
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
    SidebarCollectionMoveIntent,
    @escaping @MainActor @Sendable (Bool) -> Void
  ) -> Void
  let toggleDisclosure: (SidebarCollectionNodeID) -> Void
  let externalDropTarget: (
    ChatListItem.Identifier
  ) -> SidebarCollectionExternalDropTarget?
  let externalDropTargetChanged: (ChatListItem.Identifier?) -> Void
  let performExternalDrop: (SidebarCollectionExternalDropTarget, NSPasteboard) -> Bool
}
