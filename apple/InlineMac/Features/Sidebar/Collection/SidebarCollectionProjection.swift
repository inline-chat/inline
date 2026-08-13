import Foundation
import InlineKit
import InlineMacUI

struct SidebarProjectedItem: Equatable, Identifiable {
  let item: SidebarViewModel.Item
  let depth: Int
  let semanticParentID: ChatListItem.Identifier?
  let parentID: ChatListItem.Identifier?
  /// The lane used to persist this item's dialog order. Descendants may be
  /// presented in their root's lane without changing their own pinned state.
  let orderLane: SidebarOrderLane?
  let lane: SidebarOrderLane?
  let childCount: Int
  let isExpanded: Bool

  var id: ChatListItem.Identifier { item.id }
  var isExpandable: Bool { childCount > 0 }
}

/// Presentation containment is a product-mode choice, independent of the
/// semantic reply relationship retained on every node.
enum SidebarCollectionNestingPolicy {
  case replyThreads
  case flat
}

/// App-facing adapter around the dependency-free hierarchy model. The tree
/// retains every semantic node, including children hidden by collapse, while
/// `projectedItems()` is the only visible flattening boundary.
struct SidebarCollectionTree {
  typealias NodeID = ChatListItem.Identifier
  typealias SectionID = SidebarOrderLane?
  typealias Node = SidebarCollectionNode<NodeID>
  typealias Section = SidebarCollectionSection<NodeID, SectionID>
  typealias Snapshot = SidebarCollectionSnapshot<NodeID, SectionID>

  let snapshot: Snapshot
  let itemByID: [ChatListItem.Identifier: SidebarViewModel.Item]
  let orderLaneByID: [ChatListItem.Identifier: SidebarOrderLane]

  func replacing(snapshot: Snapshot) -> Self {
    Self(
      snapshot: snapshot,
      itemByID: itemByID,
      orderLaneByID: orderLaneByID
    )
  }

  func projectedItems(
    orderLaneOverrides: [ChatListItem.Identifier: SidebarOrderLane] = [:]
  ) -> [SidebarProjectedItem] {
    snapshot.visibleProjection().compactMap { projected in
      guard let item = itemByID[projected.id],
            let node = snapshot.nodes[projected.id]
      else { return nil }
      let isExpanded = node.childIDs.isEmpty == false && node.isExpanded
      return SidebarProjectedItem(
        item: item,
        depth: projected.depth,
        semanticParentID: node.semanticParentID,
        parentID: projected.parentID,
        orderLane: orderLaneOverrides[projected.id] ?? orderLaneByID[projected.id],
        lane: projected.sectionID,
        childCount: node.childIDs.count,
        isExpanded: isExpanded
      )
    }
  }
}

enum SidebarCollectionProjection {
  private struct Input {
    let item: SidebarViewModel.Item
    let lane: SidebarOrderLane?
  }

  /// Produces a stable pre-order traversal without changing persisted chat ordering.
  /// A reply is nested only when its parent is present in the input.
  static func project(
    _ items: [SidebarViewModel.Item],
    lane: SidebarOrderLane?,
    collapsedParentIDs: Set<ChatListItem.Identifier> = [],
    detachedReplyIDs: Set<ChatListItem.Identifier> = []
  ) -> [SidebarProjectedItem] {
    makeTree(
      items.map { Input(item: $0, lane: lane) },
      sectionIDs: [lane],
      collapsedParentIDs: collapsedParentIDs,
      detachedReplyIDs: detachedReplyIDs,
      nestingPolicy: .replyThreads,
      sortMode: nil
    ).projectedItems()
  }

  /// Projects the sidebar according to the mode's explicit containment policy.
  /// A nested child must share its parent's pinned/normal lane.
  static func projectSidebar(
    pinnedItems: [SidebarViewModel.Item],
    normalItems: [SidebarViewModel.Item],
    collapsedParentIDs: Set<ChatListItem.Identifier> = [],
    detachedReplyIDs: Set<ChatListItem.Identifier> = [],
    nestingPolicy: SidebarCollectionNestingPolicy = .replyThreads,
    sortMode: SidebarSortMode = .openedOrder
  ) -> [SidebarProjectedItem] {
    sidebarTree(
      pinnedItems: pinnedItems,
      normalItems: normalItems,
      collapsedParentIDs: collapsedParentIDs,
      detachedReplyIDs: detachedReplyIDs,
      nestingPolicy: nestingPolicy,
      sortMode: sortMode
    ).projectedItems()
  }

  static func sidebarTree(
    pinnedItems: [SidebarViewModel.Item],
    normalItems: [SidebarViewModel.Item],
    collapsedParentIDs: Set<ChatListItem.Identifier> = [],
    detachedReplyIDs: Set<ChatListItem.Identifier> = [],
    nestingPolicy: SidebarCollectionNestingPolicy = .replyThreads,
    sortMode: SidebarSortMode = .openedOrder
  ) -> SidebarCollectionTree {
    let sectionIDs: [SidebarOrderLane?] = [.pinned, .normal]
    return makeTree(
      pinnedItems.map { Input(item: $0, lane: .pinned) }
        + normalItems.map { Input(item: $0, lane: .normal) },
      sectionIDs: sectionIDs,
      collapsedParentIDs: collapsedParentIDs,
      detachedReplyIDs: detachedReplyIDs,
      nestingPolicy: nestingPolicy,
      sortMode: sortMode
    )
  }

  private static func makeTree(
    _ inputs: [Input],
    sectionIDs: [SidebarOrderLane?],
    collapsedParentIDs: Set<ChatListItem.Identifier>,
    detachedReplyIDs: Set<ChatListItem.Identifier>,
    nestingPolicy: SidebarCollectionNestingPolicy,
    sortMode: SidebarSortMode?
  ) -> SidebarCollectionTree {
    let itemByChatID = Dictionary(
      inputs.filter { $0.item.chatId != 0 }.map { ($0.item.chatId, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let inputByID = Dictionary(
      inputs.map { ($0.item.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    var semanticParentByID: [ChatListItem.Identifier: ChatListItem.Identifier] = [:]
    var presentationParentByID: [ChatListItem.Identifier: ChatListItem.Identifier] = [:]

    for input in inputs {
      let item = input.item
      if let parentChatID = item.parentChatId,
         let parent = itemByChatID[parentChatID],
         parent.item.id != item.id {
        semanticParentByID[item.id] = parent.item.id
        // A visual subtree may never cross a pinned/normal section boundary.
        // The semantic parent is still retained so an Inbox reply can reattach
        // after its own pin state changes. All Chats intentionally stays flat.
        if nestingPolicy == .replyThreads,
           detachedReplyIDs.contains(item.id) == false,
           input.lane == parent.lane {
          presentationParentByID[item.id] = parent.item.id
        }
      }
    }

    // Break invalid parent cycles at the containment boundary. Semantic
    // identity remains intact, while every affected node has deterministic
    // placement instead of disappearing from the collection snapshot.
    for input in inputs {
      var path: [ChatListItem.Identifier] = []
      var indexByID: [ChatListItem.Identifier: Int] = [:]
      var cursor = input.item.id
      while let parentID = presentationParentByID[cursor] {
        indexByID[cursor] = path.count
        path.append(cursor)
        if let cycleStart = indexByID[parentID] {
          for cycleID in path[cycleStart...] {
            presentationParentByID[cycleID] = nil
          }
          break
        }
        cursor = parentID
      }
    }

    var childrenByParentID: [ChatListItem.Identifier: [ChatListItem.Identifier]] = [:]
    for input in inputs {
      if let parentID = presentationParentByID[input.item.id] {
        childrenByParentID[parentID, default: []].append(input.item.id)
      }
    }

    let activityOrdering = SidebarCollectionActivityOrdering(
      childrenByParentID: childrenByParentID,
      activityByNodeID: inputByID.mapValues(\.item.lastActivityAt),
      stableIDs: inputs.map(\.item.id)
    )

    if sortMode == .recentActivity {
      for parentID in childrenByParentID.keys {
        childrenByParentID[parentID] = activityOrdering.ordered(
          childrenByParentID[parentID] ?? []
        )
      }
    }

    let sections: [SidebarCollectionTree.Section] = sectionIDs.map { sectionID in
      var rootIDs: [ChatListItem.Identifier] = inputs.compactMap { input in
        guard input.lane == sectionID,
              presentationParentByID[input.item.id] == nil
        else { return nil }
        return input.item.id
      }
      if sortMode == .recentActivity {
        rootIDs = activityOrdering.ordered(rootIDs)
      }
      return SidebarCollectionSection(
        id: sectionID,
        rootIDs: rootIDs
      )
    }
    let nodes: [SidebarCollectionTree.Node] = inputs.map { input in
      SidebarCollectionNode(
        id: input.item.id,
        semanticParentID: semanticParentByID[input.item.id],
        childPolicy: .semanticParentOnly,
        childIDs: childrenByParentID[input.item.id] ?? [],
        isExpanded: collapsedParentIDs.contains(input.item.id) == false
      )
    }

    let snapshot: SidebarCollectionTree.Snapshot
    do {
      snapshot = try SidebarCollectionSnapshot(sections: sections, nodes: nodes)
    } catch {
      assertionFailure("Sidebar collection projection could not form a valid snapshot")
      let fallbackSections = sectionIDs.map { sectionID in
        SidebarCollectionSection(
          id: sectionID,
          rootIDs: inputs.compactMap { input in
            input.lane == sectionID ? input.item.id : nil
          }
        )
      }
      let fallbackNodes = inputs.map { input in
        SidebarCollectionNode(
          id: input.item.id,
          semanticParentID: semanticParentByID[input.item.id]
        )
      }
      guard let fallback = try? SidebarCollectionSnapshot(
        sections: fallbackSections,
        nodes: fallbackNodes
      ) else {
        preconditionFailure("Sidebar collection fallback projection is invalid")
      }
      snapshot = fallback
    }

    return SidebarCollectionTree(
      snapshot: snapshot,
      itemByID: inputByID.mapValues(\.item),
      orderLaneByID: Dictionary(
        uniqueKeysWithValues: inputs.compactMap { input in
          input.lane.map { (input.item.id, $0) }
        }
      )
    )
  }
}
