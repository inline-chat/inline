import InlineKit

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
    project(
      items.map { Input(item: $0, lane: lane) },
      collapsedParentIDs: collapsedParentIDs,
      detachedReplyIDs: detachedReplyIDs
    )
  }

  /// Projects the inbox as one hierarchy. Descendants inherit their root's
  /// visual lane so pinning a parent cannot flatten its reply threads into a
  /// separate section.
  static func projectInbox(
    pinnedItems: [SidebarViewModel.Item],
    normalItems: [SidebarViewModel.Item],
    collapsedParentIDs: Set<ChatListItem.Identifier> = [],
    detachedReplyIDs: Set<ChatListItem.Identifier> = []
  ) -> [SidebarProjectedItem] {
    project(
      pinnedItems.map { Input(item: $0, lane: .pinned) }
        + normalItems.map { Input(item: $0, lane: .normal) },
      collapsedParentIDs: collapsedParentIDs,
      detachedReplyIDs: detachedReplyIDs
    )
  }

  private static func project(
    _ inputs: [Input],
    collapsedParentIDs: Set<ChatListItem.Identifier>,
    detachedReplyIDs: Set<ChatListItem.Identifier>
  ) -> [SidebarProjectedItem] {
    let itemByChatID = Dictionary(
      inputs.filter { $0.item.chatId != 0 }.map { ($0.item.chatId, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    var semanticParentByID: [ChatListItem.Identifier: ChatListItem.Identifier] = [:]
    var childrenByParentID: [ChatListItem.Identifier: [Input]] = [:]
    var roots: [Input] = []

    for input in inputs {
      let item = input.item
      if let parentChatID = item.parentChatId,
         let parent = itemByChatID[parentChatID],
         parent.item.id != item.id {
        semanticParentByID[item.id] = parent.item.id
        let isPinnedAboveUnpinnedParent = input.lane == .pinned && parent.lane != .pinned
        if detachedReplyIDs.contains(item.id) || isPinnedAboveUnpinnedParent {
          roots.append(input)
        } else {
          childrenByParentID[parent.item.id, default: []].append(input)
        }
      } else {
        roots.append(input)
      }
    }

    var result: [SidebarProjectedItem] = []
    var visited = Set<ChatListItem.Identifier>()

    func consumeHiddenDescendants(of parentID: ChatListItem.Identifier) {
      for child in childrenByParentID[parentID] ?? [] {
        guard visited.insert(child.item.id).inserted else { continue }
        consumeHiddenDescendants(of: child.item.id)
      }
    }

    func append(
      _ input: Input,
      depth: Int,
      parentID: ChatListItem.Identifier?,
      inheritedLane: SidebarOrderLane?
    ) {
      let item = input.item
      guard visited.insert(item.id).inserted else { return }
      let children = childrenByParentID[item.id] ?? []
      let isExpanded = children.isEmpty == false && collapsedParentIDs.contains(item.id) == false
      let visualLane = parentID == nil ? input.lane : inheritedLane
      result.append(SidebarProjectedItem(
        item: item,
        depth: depth,
        semanticParentID: semanticParentByID[item.id],
        parentID: parentID,
        orderLane: input.lane,
        lane: visualLane,
        childCount: children.count,
        isExpanded: isExpanded
      ))

      guard isExpanded else {
        consumeHiddenDescendants(of: item.id)
        return
      }
      for child in children {
        append(child, depth: depth + 1, parentID: item.id, inheritedLane: visualLane)
      }
    }

    for root in roots {
      append(root, depth: 0, parentID: nil, inheritedLane: root.lane)
    }

    // Cycles are invalid data, but keeping their original order is safer than dropping rows.
    for input in inputs where visited.contains(input.item.id) == false {
      append(input, depth: 0, parentID: nil, inheritedLane: input.lane)
    }

    return result
  }
}
