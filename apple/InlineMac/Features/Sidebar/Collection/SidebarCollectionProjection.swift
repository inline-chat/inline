import Foundation
import InlineKit
import InlineMacSidebarModel
import InlineMacUI

enum SidebarCollectionNodeID: Hashable, Sendable {
  case chat(ChatListItem.Identifier)
  case folder(Int64)

  var chatID: ChatListItem.Identifier? {
    guard case let .chat(id) = self else { return nil }
    return id
  }

  var folderID: Int64? {
    guard case let .folder(id) = self else { return nil }
    return id
  }
}

struct SidebarProjectedItem: Equatable, Identifiable {
  let item: SidebarViewModel.Item
  let depth: Int
  let semanticParentID: ChatListItem.Identifier?
  let parentID: SidebarCollectionNodeID?
  /// The lane used to persist this item's dialog order. Descendants may be
  /// presented in their root's lane without changing their own pinned state.
  let orderLane: SidebarOrderLane?
  let lane: SidebarOrderLane?
  let childCount: Int
  let isExpanded: Bool

  var id: ChatListItem.Identifier { item.id }
  var nodeID: SidebarCollectionNodeID { .chat(id) }
  var isExpandable: Bool { childCount > 0 }
  var showsIcon: Bool { depth == 0 || parentID?.folderID != nil }
}

struct SidebarProjectedFolder: Equatable, Identifiable {
  let folder: SidebarViewModel.Folder
  let depth: Int
  let lane: SidebarOrderLane
  let childCount: Int
  let unreadCount: Int
  let prominentUnreadCount: Int
  let isExpanded: Bool

  var id: Int64 { folder.id }
  var nodeID: SidebarCollectionNodeID { .folder(id) }
  var title: String {
    if let title = folder.title?.trimmingCharacters(in: .whitespacesAndNewlines),
       title.isEmpty == false {
      return title
    }
    return "\(childCount) Chat\(childCount == 1 ? "" : "s")"
  }
}

enum SidebarProjectedNode: Equatable, Identifiable {
  case chat(SidebarProjectedItem)
  case folder(SidebarProjectedFolder)

  var id: SidebarCollectionNodeID {
    switch self {
    case let .chat(item): item.nodeID
    case let .folder(folder): folder.nodeID
    }
  }

  var lane: SidebarOrderLane? {
    switch self {
    case let .chat(item): item.lane
    case let .folder(folder): folder.lane
    }
  }

  var projectedItem: SidebarProjectedItem? {
    guard case let .chat(item) = self else { return nil }
    return item
  }
}

/// Presentation containment is configuration, not an expanding state enum.
/// Reply nesting and personal folders can evolve independently.
struct SidebarCollectionNestingPolicy: Equatable {
  let nestsReplyThreads: Bool
  let presentsFolders: Bool

  static let replyThreads = Self(nestsReplyThreads: true, presentsFolders: false)
  static let inbox = Self(nestsReplyThreads: true, presentsFolders: true)
  static let flat = Self(nestsReplyThreads: false, presentsFolders: false)
}

/// App-facing adapter around the dependency-free hierarchy model. The tree
/// retains every semantic node, including children hidden by collapse, while
/// `projectedNodes()` is the only visible flattening boundary.
struct SidebarCollectionTree {
  typealias NodeID = SidebarCollectionNodeID
  typealias SectionID = SidebarOrderLane?
  typealias Node = SidebarCollectionNode<NodeID>
  typealias Section = SidebarCollectionSection<NodeID, SectionID>
  typealias Snapshot = SidebarCollectionSnapshot<NodeID, SectionID>

  let snapshot: Snapshot
  let itemByID: [ChatListItem.Identifier: SidebarViewModel.Item]
  let folderByID: [Int64: SidebarViewModel.Folder]
  let orderLaneByID: [NodeID: SidebarOrderLane]
  let semanticReplyParentByID: [ChatListItem.Identifier: ChatListItem.Identifier]

  func replacing(snapshot: Snapshot) -> Self {
    Self(
      snapshot: snapshot,
      itemByID: itemByID,
      folderByID: folderByID,
      orderLaneByID: orderLaneByID,
      semanticReplyParentByID: semanticReplyParentByID
    )
  }

  func projectedNodes(
    orderLaneOverrides: [ChatListItem.Identifier: SidebarOrderLane] = [:]
  ) -> [SidebarProjectedNode] {
    snapshot.visibleProjection().compactMap { projected in
      guard let node = snapshot.nodes[projected.id] else { return nil }
      let isExpanded = node.childIDs.isEmpty == false && node.isExpanded
      switch projected.id {
      case let .chat(id):
        guard let item = itemByID[id] else { return nil }
        return .chat(SidebarProjectedItem(
          item: item,
          depth: projected.depth,
          semanticParentID: semanticReplyParentByID[id],
          parentID: projected.parentID,
          orderLane: orderLaneOverrides[id] ?? orderLaneByID[projected.id],
          lane: projected.sectionID,
          childCount: node.childIDs.count,
          isExpanded: isExpanded
        ))
      case let .folder(id):
        guard let folder = folderByID[id], let lane = projected.sectionID else { return nil }
        let unreadCount = node.childIDs.lazy.compactMap(\.chatID).reduce(into: 0) { count, id in
          if itemByID[id]?.unread == true { count += 1 }
        }
        let prominentUnreadCount = node.childIDs.lazy.compactMap(\.chatID).reduce(into: 0) {
          count, id in
          if let item = itemByID[id], item.unread, item.prominentUnreadDot { count += 1 }
        }
        return .folder(SidebarProjectedFolder(
          folder: folder,
          depth: projected.depth,
          lane: lane,
          childCount: node.childIDs.count,
          unreadCount: unreadCount,
          prominentUnreadCount: prominentUnreadCount,
          isExpanded: isExpanded
        ))
      }
    }
  }

  func projectedItems(
    orderLaneOverrides: [ChatListItem.Identifier: SidebarOrderLane] = [:]
  ) -> [SidebarProjectedItem] {
    projectedNodes(orderLaneOverrides: orderLaneOverrides).compactMap { node in
      guard case let .chat(item) = node else { return nil }
      return item
    }
  }

  func persistedOrder(
    for nodeID: NodeID,
    lane: SidebarOrderLane
  ) -> String? {
    switch nodeID {
    case let .chat(id):
      guard let item = itemByID[id] else { return nil }
      return lane == .pinned ? item.pinnedOrder : item.order
    case let .folder(id):
      guard lane == .normal else { return nil }
      return folderByID[id]?.order
    }
  }

  /// A root insertion after a folder must follow the folder's complete order
  /// interval, not merely the folder header coordinate.
  func trailingPersistedOrder(
    for nodeID: NodeID,
    lane: SidebarOrderLane
  ) -> String? {
    guard case .folder = nodeID,
          let node = snapshot.nodes[nodeID]
    else { return persistedOrder(for: nodeID, lane: lane) }
    return node.childIDs.compactMap { persistedOrder(for: $0, lane: lane) }.max()
      ?? persistedOrder(for: nodeID, lane: lane)
  }
}

enum SidebarCollectionProjection {
  private struct Input {
    let id: SidebarCollectionNodeID
    let item: SidebarViewModel.Item?
    let folder: SidebarViewModel.Folder?
    let lane: SidebarOrderLane?
    let order: String?
    let activity: Date

    var stableKey: String {
      switch id {
      case let .chat(id): "chat:\(id.kind.rawValue):\(id.rawValue)"
      case let .folder(id): "folder:\(id)"
      }
    }
  }

  static func project(
    _ items: [SidebarViewModel.Item],
    lane: SidebarOrderLane?,
    collapsedParentIDs: Set<ChatListItem.Identifier> = [],
    detachedReplyIDs: Set<ChatListItem.Identifier> = []
  ) -> [SidebarProjectedItem] {
    makeTree(
      chatInputs(items, lane: lane),
      sectionIDs: [lane],
      collapsedParentIDs: collapsedParentIDs,
      collapsedFolderIDs: [],
      detachedReplyIDs: detachedReplyIDs,
      nestingPolicy: .replyThreads,
      sortMode: nil
    ).projectedItems()
  }

  static func projectSidebar(
    pinnedItems: [SidebarViewModel.Item],
    normalItems: [SidebarViewModel.Item],
    folders: [SidebarViewModel.Folder] = [],
    collapsedParentIDs: Set<ChatListItem.Identifier> = [],
    collapsedFolderIDs: Set<Int64> = [],
    detachedReplyIDs: Set<ChatListItem.Identifier> = [],
    nestingPolicy: SidebarCollectionNestingPolicy = .replyThreads,
    sortMode: SidebarSortMode = .openedOrder
  ) -> [SidebarProjectedNode] {
    sidebarTree(
      pinnedItems: pinnedItems,
      normalItems: normalItems,
      folders: folders,
      collapsedParentIDs: collapsedParentIDs,
      collapsedFolderIDs: collapsedFolderIDs,
      detachedReplyIDs: detachedReplyIDs,
      nestingPolicy: nestingPolicy,
      sortMode: sortMode
    ).projectedNodes()
  }

  static func sidebarTree(
    pinnedItems: [SidebarViewModel.Item],
    normalItems: [SidebarViewModel.Item],
    folders: [SidebarViewModel.Folder] = [],
    collapsedParentIDs: Set<ChatListItem.Identifier> = [],
    collapsedFolderIDs: Set<Int64> = [],
    detachedReplyIDs: Set<ChatListItem.Identifier> = [],
    nestingPolicy: SidebarCollectionNestingPolicy = .replyThreads,
    sortMode: SidebarSortMode = .openedOrder
  ) -> SidebarCollectionTree {
    let presentedFolders = nestingPolicy.presentsFolders ? folders : []
    let inputs = chatInputs(pinnedItems, lane: .pinned)
      + chatInputs(normalItems, lane: .normal)
      + presentedFolders.map { folder in
        Input(
          id: .folder(folder.id),
          item: nil,
          folder: folder,
          lane: .normal,
          order: folder.order,
          activity: .distantPast
        )
      }
    return makeTree(
      inputs,
      sectionIDs: [.pinned, .normal],
      collapsedParentIDs: collapsedParentIDs,
      collapsedFolderIDs: collapsedFolderIDs,
      detachedReplyIDs: detachedReplyIDs,
      nestingPolicy: nestingPolicy,
      sortMode: sortMode
    )
  }

  private static func chatInputs(
    _ items: [SidebarViewModel.Item],
    lane: SidebarOrderLane?
  ) -> [Input] {
    items.map { item in
      Input(
        id: .chat(item.id),
        item: item,
        folder: nil,
        lane: lane,
        order: lane == .pinned ? item.pinnedOrder : item.order,
        activity: item.lastActivityAt
      )
    }
  }

  private static func makeTree(
    _ rawInputs: [Input],
    sectionIDs: [SidebarOrderLane?],
    collapsedParentIDs: Set<ChatListItem.Identifier>,
    collapsedFolderIDs: Set<Int64>,
    detachedReplyIDs: Set<ChatListItem.Identifier>,
    nestingPolicy: SidebarCollectionNestingPolicy,
    sortMode: SidebarSortMode?
  ) -> SidebarCollectionTree {
    // Corrupt or duplicated source rows must not reach Dictionary's trapping
    // initializer or make the entire sidebar disappear. Preserve the first
    // complete source value for each stable identity, matching GRDB's ordered
    // snapshot semantics.
    var seenInputIDs = Set<SidebarCollectionNodeID>()
    let inputs = rawInputs.filter { seenInputIDs.insert($0.id).inserted }
    let itemByChatID = Dictionary(
      inputs.compactMap { input in input.item.map { ($0.chatId, input) } },
      uniquingKeysWith: { first, _ in first }
    )
    let inputByID = Dictionary(
      inputs.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let folderIDs = Set(inputs.compactMap { $0.folder?.id })
    var semanticReplyParentByID: [ChatListItem.Identifier: ChatListItem.Identifier] = [:]
    var semanticParentByID: [SidebarCollectionNodeID: SidebarCollectionNodeID] = [:]
    var presentationParentByID: [SidebarCollectionNodeID: SidebarCollectionNodeID] = [:]

    for input in inputs {
      guard let item = input.item else { continue }
      let replyParent = item.parentChatId.flatMap { itemByChatID[$0] }
      if let childID = input.id.chatID,
         let parentID = replyParent?.id.chatID,
         parentID != childID {
        semanticReplyParentByID[childID] = parentID
      }
      if nestingPolicy.presentsFolders,
         let folderID = item.folderID,
         folderIDs.contains(folderID),
         input.lane == .normal {
        semanticParentByID[input.id] = .folder(folderID)
        presentationParentByID[input.id] = .folder(folderID)
        continue
      }
      if let parent = replyParent,
         parent.id != input.id {
        semanticParentByID[input.id] = parent.id
        let pinnedParentOwnsPresentation = parent.lane == .pinned
        if nestingPolicy.nestsReplyThreads,
           pinnedParentOwnsPresentation
             || (detachedReplyIDs.contains(item.id) == false && input.lane == parent.lane) {
          presentationParentByID[input.id] = parent.id
        }
      }
    }

    breakCycles(in: &presentationParentByID, inputs: inputs)

    var childrenByParentID: [SidebarCollectionNodeID: [SidebarCollectionNodeID]] = [:]
    for input in inputs {
      if let parentID = presentationParentByID[input.id] {
        childrenByParentID[parentID, default: []].append(input.id)
      }
    }
    let activityOrdering = SidebarCollectionActivityOrdering(
      childrenByParentID: childrenByParentID,
      activityByNodeID: inputByID.mapValues(\.activity),
      stableIDs: inputs.map(\.id)
    )
    for parentID in childrenByParentID.keys {
      if sortMode == .recentActivity {
        childrenByParentID[parentID] = activityOrdering.ordered(
          childrenByParentID[parentID] ?? []
        )
      } else {
        childrenByParentID[parentID]?.sort {
          ordered($0, before: $1, inputs: inputByID, byActivity: false)
        }
      }
    }

    let sections: [SidebarCollectionTree.Section] = sectionIDs.map { sectionID in
      var roots = inputs.compactMap { input -> SidebarCollectionNodeID? in
        guard input.lane == sectionID, presentationParentByID[input.id] == nil else { return nil }
        return input.id
      }
      if sortMode == .recentActivity, sectionID == .normal {
        let folders = roots.filter { $0.folderID != nil }.sorted {
          ordered($0, before: $1, inputs: inputByID, byActivity: false)
        }
        let chats = activityOrdering.ordered(roots.filter { $0.chatID != nil })
        roots = folders + chats
      } else if sortMode == .recentActivity {
        roots = activityOrdering.ordered(roots)
      } else {
        roots.sort {
          ordered($0, before: $1, inputs: inputByID, byActivity: false)
        }
      }
      return SidebarCollectionSection(id: sectionID, rootIDs: roots)
    }

    let nodes = inputs.map { input in
      let isExpanded: Bool = switch input.id {
      case let .chat(id): collapsedParentIDs.contains(id) == false
      case let .folder(id): collapsedFolderIDs.contains(id) == false
      }
      return SidebarCollectionNode(
        id: input.id,
        semanticParentID: semanticParentByID[input.id],
        childPolicy: input.folder == nil ? .semanticParentOnly : .any,
        childIDs: childrenByParentID[input.id] ?? [],
        isExpanded: isExpanded
      )
    }

    let snapshot: SidebarCollectionTree.Snapshot
    do {
      snapshot = try SidebarCollectionSnapshot(sections: sections, nodes: nodes)
    } catch {
      let fallbackNodes = inputs.map { SidebarCollectionNode(id: $0.id) }
      let fallbackSections = sectionIDs.map { sectionID in
        SidebarCollectionSection(
          id: sectionID,
          rootIDs: inputs.filter { $0.lane == sectionID }.map(\.id)
        )
      }
      snapshot = (try? SidebarCollectionSnapshot(sections: fallbackSections, nodes: fallbackNodes))
        ?? emptySnapshot(sectionIDs: sectionIDs)
    }

    return SidebarCollectionTree(
      snapshot: snapshot,
      itemByID: Dictionary(
        inputs.compactMap { $0.item.map { ($0.id, $0) } },
        uniquingKeysWith: { first, _ in first }
      ),
      folderByID: Dictionary(
        inputs.compactMap { $0.folder.map { ($0.id, $0) } },
        uniquingKeysWith: { first, _ in first }
      ),
      orderLaneByID: Dictionary(
        inputs.compactMap { input in input.lane.map { (input.id, $0) } },
        uniquingKeysWith: { first, _ in first }
      ),
      semanticReplyParentByID: semanticReplyParentByID
    )
  }

  private static func emptySnapshot(
    sectionIDs: [SidebarOrderLane?]
  ) -> SidebarCollectionTree.Snapshot {
    // Empty sections are always a valid last-resort presentation. This avoids a
    // release crash if corrupted local data violates projection invariants.
    SidebarCollectionSnapshot(emptySectionIDs: sectionIDs)
  }

  private static func breakCycles(
    in parents: inout [SidebarCollectionNodeID: SidebarCollectionNodeID],
    inputs: [Input]
  ) {
    for input in inputs {
      var path: [SidebarCollectionNodeID] = []
      var indexByID: [SidebarCollectionNodeID: Int] = [:]
      var cursor = input.id
      while let parentID = parents[cursor] {
        indexByID[cursor] = path.count
        path.append(cursor)
        if let cycleStart = indexByID[parentID] {
          for cycleID in path[cycleStart...] { parents[cycleID] = nil }
          break
        }
        cursor = parentID
      }
    }
  }

  private static func ordered(
    _ lhsID: SidebarCollectionNodeID,
    before rhsID: SidebarCollectionNodeID,
    inputs: [SidebarCollectionNodeID: Input],
    byActivity: Bool
  ) -> Bool {
    guard let lhs = inputs[lhsID], let rhs = inputs[rhsID] else { return false }
    if byActivity, lhs.activity != rhs.activity { return lhs.activity > rhs.activity }
    switch (lhs.order, rhs.order) {
    case let (lhsOrder?, rhsOrder?) where lhsOrder != rhsOrder:
      return lhsOrder < rhsOrder
    case (_?, nil):
      return true
    case (nil, _?):
      return false
    default:
      return lhs.stableKey < rhs.stableKey
    }
  }
}
