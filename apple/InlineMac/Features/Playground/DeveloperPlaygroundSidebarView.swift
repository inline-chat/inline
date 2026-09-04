#if DEBUG || DEBUG_BUILD
import AppKit
import InlineKit
import InlineMacSidebarModel
import InlineMacUI
import Observation
import SwiftUI

@MainActor
@Observable
final class DeveloperSidebarPlaygroundModel {
  struct ActionEvent: Equatable, Identifiable {
    let id: Int
    let message: String
  }

  enum Layout: String, CaseIterable, Identifiable {
    case inbox
    case allChats
    case archived

    var id: Self { self }

    var title: String {
      switch self {
      case .inbox: "Inbox"
      case .allChats: "All Chats"
      case .archived: "Archived"
      }
    }
  }

  struct Chat: Equatable, Identifiable {
    let id: Int64
    var lane: SidebarOrderLane
    var parentChatID: Int64?
    var title: String
    var preview: String
    var identity: ChatListIdentityDescriptor
    var unreadCount: Int
    var unreadMark: Bool
    var prominent: Bool
    var isTemporary: Bool
    var showsCloseButton: Bool

    var peer: Peer { .thread(id: id) }

    var sidebarItem: SidebarViewModel.Item {
      SidebarViewModel.Item(snapshot: ChatListItemSnapshot(
        dialogID: id,
        peer: peer,
        chatID: id,
        parentChatID: parentChatID,
        title: title,
        previewText: preview,
        identity: identity,
        unreadCount: unreadCount,
        unreadMark: unreadMark,
        prominence: prominent ? .prominent : .standard,
        isOpen: true,
        isPinned: lane == .pinned,
        lastUpdatedAt: Self.referenceDate.addingTimeInterval(TimeInterval(-id * 43)),
        order: lane == .normal ? String(id) : nil,
        pinnedOrder: lane == .pinned ? String(id) : nil
      ))
    }

    static let referenceDate = Date(timeIntervalSince1970: 1_787_190_400)
  }

  private struct CatalogChat {
    let id: Int64
    let title: String
    var preview = ""
    let identity: ChatListIdentityDescriptor
    var selected = false
    var size = SidebarItemSize.standard
    var unreadCount = 0
    var unreadMark = false
    var prominent = false
    var style = UnreadBadgeStyle.dot
    var indentationLevel = 0
    var showsIcon = true
    var disclosureExpanded: Bool?
    var showsCloseButton = false
    var isTemporary = false
    var isDropTargeted = false
    var forceHoverAppearance = false
  }

  var layout = Layout.inbox
  var itemSize = SidebarItemSize.standard
  var unreadBadgeStyle = UnreadBadgeStyle.dot
  var animationsEnabled = true
  var pinnedExpanded = true
  var contentExpanded = true
  var collapsedParentIDs: Set<ChatListItem.Identifier> = []
  var selectedID: Int64? = 1_001
  var chats = DeveloperSidebarPlaygroundModel.initialChats
  var actionLog = [ActionEvent(
    id: 0,
    message: "Ready — interactions are local to this playground."
  )]
  private var nextChatID: Int64 = 2_000
  private var nextActionEventID = 1

  var selectedPeer: Peer? {
    selectedID.map { .thread(id: $0) }
  }

  var selectedChat: Chat? {
    guard let selectedID else { return nil }
    return chats.first { $0.id == selectedID }
  }

  var tree: SidebarCollectionTree {
    SidebarCollectionProjection.sidebarTree(
      pinnedItems: chats.filter { $0.lane == .pinned }.map(\.sidebarItem),
      normalItems: chats.filter { $0.lane == .normal }.map(\.sidebarItem),
      collapsedParentIDs: collapsedParentIDs,
      nestingPolicy: layout == .allChats ? .flat : .replyThreads,
      sortMode: .openedOrder
    )
  }

  var rows: [SidebarCollectionRow] {
    let projected = tree.projectedItems()
    let pinned = projected.filter { $0.lane == .pinned }
    let normal = projected.filter { $0.lane == .normal }
    var result: [SidebarCollectionRow] = []

    switch layout {
    case .inbox:
      result.append(navigationRow(id: .allChats, kind: .allChats))
      result.append(navigationRow(id: .grid, kind: .grid))
    case .allChats:
      result.append(navigationRow(id: .newThread, kind: .newThread))
    case .archived:
      result.append(SidebarCollectionRow(
        id: .archiveHeader,
        kind: .archiveHeader,
        height: SidebarCollectionRow.spacedSectionHeaderHeight
      ))
    }

    if pinned.isEmpty == false, layout != .archived {
      result.append(.sectionHeader(
        .pinned,
        isExpanded: pinnedExpanded,
        height: SidebarCollectionRow.pinnedSectionHeaderHeight
      ))
      if pinnedExpanded {
        result.append(contentsOf: chatRows(pinned))
      } else if let selected = selectedProjectedItem(in: pinned) {
        result.append(contentsOf: chatRows([selected]))
      }
    }

    switch layout {
    case .inbox:
      result.append(.sectionHeader(.content, isExpanded: contentExpanded))
      if contentExpanded {
        // New thread belongs to Open's disclosed block, matching production.
        result.append(navigationRow(
          id: .newThread,
          kind: .newThread,
          height: itemSize.rowHeight
        ))
        result.append(contentsOf: chatRows(normal))
      } else if let selected = selectedProjectedItem(in: normal) {
        result.append(contentsOf: chatRows([selected]))
      }
    case .allChats:
      result.append(contentsOf: SidebarCollectionRow.timelineRows(
        normal,
        chatRowHeight: itemSize.rowHeight,
        relativeTo: Chat.referenceDate
      ))
    case .archived:
      result.append(contentsOf: chatRows(normal))
    }
    return result
  }

  var renderState: SidebarCollectionRenderState {
    SidebarCollectionRenderState(
      selectedPeer: selectedPeer,
      selectedReplyPeer: nil,
      allChatsSelected: false,
      gridSelectionKey: "playground-grid",
      titlesDimmed: false,
      scopedProminentUnreadCount: chats.filter { $0.prominent && $0.unreadCount > 0 }.count,
      scopedOtherUnreadCount: chats.filter { !$0.prominent && $0.unreadCount > 0 }.count,
      homeGridAvatarIDs: [31, 32],
      sidebarAsInbox: layout == .inbox,
      archiveVisible: layout == .archived,
      externalDropTargetID: nil,
      preview: SidebarCollectionRenderState.Preview(
        renderer: .appKit,
        itemSize: itemSize.rawValue,
        unreadBadgeStyle: unreadBadgeStyle.rawValue,
        colorScheme: "playground",
        themeRevision: 0,
        temporaryItemID: chats.first(where: \.isTemporary)?.sidebarItem.id
      )
    )
  }

  func reset() {
    layout = .inbox
    itemSize = .standard
    unreadBadgeStyle = .dot
    animationsEnabled = true
    pinnedExpanded = true
    contentExpanded = true
    collapsedParentIDs = []
    selectedID = 1_001
    chats = Self.initialChats
    nextChatID = 2_000
    actionLog = [ActionEvent(id: 0, message: "Reset the deterministic fixture scene.")]
    nextActionEventID = 1
  }

  func select(_ id: Int64) {
    selectedID = id
    record("Selected \(chatTitle(id)).")
  }

  func toggleSelectedUnread() {
    guard let selectedID,
          let index = chats.firstIndex(where: { $0.id == selectedID })
    else { return }
    let becomesUnread = chats[index].unreadCount == 0 && chats[index].unreadMark == false
    chats[index].unreadCount = becomesUnread ? 7 : 0
    chats[index].unreadMark = false
    record(becomesUnread
      ? "Inserted unread badge on \(chats[index].title)."
      : "Removed unread badge from \(chats[index].title).")
  }

  func toggleSelectedPin() {
    guard let selectedID,
          let index = chats.firstIndex(where: { $0.id == selectedID })
    else { return }
    chats[index].lane = chats[index].lane == .pinned ? .normal : .pinned
    record("Moved \(chats[index].title) to \(chats[index].lane.rawValue).")
  }

  func toggleParent(_ id: ChatListItem.Identifier) {
    if collapsedParentIDs.remove(id) == nil {
      collapsedParentIDs.insert(id)
      record("Collapsed a reply-thread group.")
    } else {
      record("Expanded a reply-thread group.")
    }
  }

  func toggleSection(_ section: SidebarCollectionRow.SectionHeader) {
    switch section {
    case .pinned:
      pinnedExpanded.toggle()
      record("Pinned is now \(pinnedExpanded ? "expanded" : "collapsed").")
    case .content:
      contentExpanded.toggle()
      record("Open is now \(contentExpanded ? "expanded" : "collapsed").")
    }
  }

  func addChat() {
    nextChatID += 1
    let id = nextChatID
    chats.append(Chat(
      id: id,
      lane: .normal,
      title: "New tab \(id - 2_000)",
      preview: "Inserted locally to exercise collection updates",
      identity: Self.threadIdentity(emoji: "✨", title: "New tab", isReply: false),
      unreadCount: 0,
      unreadMark: false,
      prominent: false,
      isTemporary: true,
      showsCloseButton: true
    ))
    selectedID = id
    record("Inserted and selected New tab \(id - 2_000).")
  }

  func close(_ id: Int64) {
    guard let index = chats.firstIndex(where: { $0.id == id }) else { return }
    let title = chats[index].title
    chats.remove(at: index)
    if selectedID == id {
      selectedID = chats.indices.contains(index)
        ? chats[index].id
        : chats.last?.id
    }
    record("Closed \(title).")
  }

  func persist(_ id: Int64) {
    guard let index = chats.firstIndex(where: { $0.id == id }) else { return }
    chats[index].isTemporary = false
    record("Kept \(chats[index].title) in the sidebar.")
  }

  func toggleRead(_ id: Int64) {
    guard let index = chats.firstIndex(where: { $0.id == id }) else { return }
    let becomesUnread = chats[index].unreadCount == 0 && chats[index].unreadMark == false
    chats[index].unreadCount = becomesUnread ? 3 : 0
    chats[index].unreadMark = false
    record(becomesUnread ? "Marked \(chats[index].title) unread." : "Marked \(chats[index].title) read.")
  }

  func togglePin(_ id: Int64) {
    guard let index = chats.firstIndex(where: { $0.id == id }) else { return }
    chats[index].lane = chats[index].lane == .pinned ? .normal : .pinned
    record("Toggled pin for \(chats[index].title).")
  }

  func apply(_ intent: SidebarCollectionMoveIntent) {
    guard case let .chat(move) = intent else {
      record("Reordered a folder fixture.")
      return
    }
    let movedID = move.movedItem.id
    guard let movedIndex = chats.firstIndex(where: { $0.sidebarItem.id == movedID }) else {
      record("Rejected a move whose fixture identity was missing.")
      return
    }

    chats[movedIndex].lane = move.targetLane
    switch move.hierarchyChange {
    case let .attach(_, parentID):
      chats[movedIndex].parentChatID = chats.first {
        $0.sidebarItem.id == parentID
      }?.id
    case .detach:
      chats[movedIndex].parentChatID = nil
    case nil:
      break
    }

    let targetOrder = Dictionary(
      uniqueKeysWithValues: move.targetItems.enumerated().map { ($0.element.id, $0.offset) }
    )
    let existingOrder = Dictionary(
      uniqueKeysWithValues: chats.enumerated().map { ($0.element.id, $0.offset) }
    )
    chats.sort { lhs, rhs in
      if lhs.lane != rhs.lane {
        return lhs.lane == .pinned
      }
      if lhs.lane == move.targetLane {
        let leftRank = targetOrder[lhs.sidebarItem.id] ?? Int.max
        let rightRank = targetOrder[rhs.sidebarItem.id] ?? Int.max
        if leftRank != rightRank { return leftRank < rightRank }
      }
      return (existingOrder[lhs.id] ?? 0) < (existingOrder[rhs.id] ?? 0)
    }
    record("Dropped \(move.movedItem.title) in \(move.targetLane.rawValue) at index \(move.newIndex).")
  }

  func nativeConfiguration(
    for row: SidebarCollectionRow,
    context: SidebarCollectionRowRenderContext
  ) -> SidebarNativeRowConfiguration {
    let content: SidebarNativeRowConfiguration.Content = switch row.kind {
    case .allChats:
      .navigation(.init(
        title: "All Chats",
        systemImage: "text.bubble",
        iconStyle: .standard,
        selected: false,
        titleDimmed: false,
        size: .compact,
        prominentUnreadCount: renderState.scopedProminentUnreadCount,
        otherUnreadCount: renderState.scopedOtherUnreadCount,
        avatars: [],
        accessibilityValue: "Fixture unread totals",
        contextMenuAction: nil,
        action: { [weak self] in self?.record("Opened All Chats.") }
      ))
    case .grid:
      .navigation(.init(
        title: "Grid",
        systemImage: "square.grid.2x2",
        iconStyle: .standard,
        selected: false,
        titleDimmed: false,
        size: .compact,
        prominentUnreadCount: 0,
        otherUnreadCount: 0,
        avatars: Self.gridAvatars,
        accessibilityValue: "Two recent participants",
        contextMenuAction: .init(
          title: "Hide Grid",
          systemImage: "eye.slash",
          action: { [weak self] in self?.record("Hid Grid from the sidebar.") }
        ),
        action: { [weak self] in self?.record("Opened Grid.") }
      ))
    case .archiveHeader:
      .header(.init(
        title: "Archived",
        style: .archive,
        isExpanded: nil,
        topSpacing: 0,
        onToggle: nil,
        onCleanUp: nil,
        onCloseAll: nil
      ))
    case let .sectionHeader(section, expanded):
      .header(.init(
        title: section == .pinned ? "Pinned" : "Open",
        style: section == .pinned ? .pinnedSection : .section,
        isExpanded: context.disclosureExpandedOverride ?? expanded,
        topSpacing: SidebarCollectionRow.sectionTopSpacing,
        onToggle: { [weak self] in self?.toggleSection(section) },
        onCleanUp: section == .content ? { [weak self] in self?.record("Selected Cleanup…") } : nil,
        onCloseAll: section == .content ? { [weak self] in self?.record("Selected Close All.") } : nil
      ))
    case let .timelineHeader(period):
      .header(.init(
        title: ChatListTimelinePeriodTitle.string(
          for: period,
          calendar: Self.fixtureCalendar
        ),
        style: .timeline,
        isExpanded: nil,
        topSpacing: 0,
        onToggle: nil,
        onCleanUp: nil,
        onCloseAll: nil
      ))
    case .pinDropGuide:
      .pinDropGuide(.init(dimsInstruction: context.dimsPinDropInstruction))
    case let .chat(projected):
      .chat(chatConfiguration(projected, context: context))
    case let .folder(folder):
      .folder(.init(
        presentation: .init(folder),
        titleDimmed: false,
        size: itemSize,
        unreadBadgeStyle: unreadBadgeStyle,
        disclosureExpanded: context.disclosureExpandedOverride ?? folder.isExpanded,
        isDropTargeted: context.isDropTargeted,
        forceHoverAppearance: context.forceHoverAppearance,
        actions: .init(
          toggleDisclosure: { [weak self] in self?.record("Toggled a folder fixture.") },
          setEmoji: { [weak self] emoji in self?.record("Selected folder emoji \(emoji).") },
          togglePin: { [weak self] in self?.record("Pinned or unpinned a folder fixture.") },
          rename: { [weak self] in self?.record("Renamed a folder fixture.") },
          close: { [weak self] in self?.record("Closed a folder fixture.") },
          ungroup: { [weak self] in self?.record("Ungrouped a folder fixture.") }
        )
      ))
    case .folderEmpty:
      .folderEmpty(.init(size: itemSize))
    case .newThread:
      .navigation(.init(
        title: "New thread",
        systemImage: "square.and.pencil",
        iconStyle: .newThread,
        selected: false,
        titleDimmed: layout == .inbox,
        size: layout == .inbox ? itemSize : .compact,
        prominentUnreadCount: 0,
        otherUnreadCount: 0,
        avatars: [],
        accessibilityValue: "",
        contextMenuAction: nil,
        action: { [weak self] in self?.addChat() }
      ))
    case .emptyState:
      .emptyState(.init(
        title: "No chats",
        systemImage: "bubble.left",
        actionTitle: "New thread",
        action: { [weak self] in self?.addChat() }
      ))
    }
    return SidebarNativeRowConfiguration(
      rowID: row.id,
      content: content,
      animatesChanges: animationsEnabled && context.suppressesAnimations == false
    )
  }

  func catalogFixtures() -> [DeveloperSidebarCatalogFixture] {
    let noopActions = SidebarNativeRowConfiguration.ChatActions(
      open: { [weak self] in self?.record("Activated catalog chat row.") },
      close: { [weak self] in self?.record("Pressed catalog close.") },
      persist: { [weak self] in self?.record("Pressed catalog Keep in Sidebar.") },
      toggleDisclosure: { [weak self] in self?.record("Pressed catalog disclosure.") },
      openInNewTab: { [weak self] in self?.record("Selected Open in New Tab.") },
      openInNewWindow: { [weak self] in self?.record("Selected Open in New Window.") },
      rename: { [weak self] in self?.record("Selected Rename Thread.") },
      togglePin: { [weak self] in self?.record("Selected Pin/Unpin.") },
      toggleReadUnread: { [weak self] in self?.record("Selected Read/Unread.") },
      toggleArchive: { [weak self] in self?.record("Selected Archive/Unarchive.") },
      folderMenu: { nil }
    )
    let compactHeight = SidebarItemSize.compact.rowHeight
    let standardHeight = SidebarItemSize.standard.rowHeight
    return [
      DeveloperSidebarCatalogFixture(
        id: "all-chats-selected",
        title: "Navigation · selected + totals",
        height: compactHeight,
        configuration: .init(
          rowID: .allChats,
          content: .navigation(.init(
            title: "All Chats",
            systemImage: "text.bubble",
            iconStyle: .standard,
            selected: true,
            titleDimmed: false,
            size: .compact,
            prominentUnreadCount: 2,
            otherUnreadCount: 5,
            avatars: [],
            accessibilityValue: "2 prominent and 5 other unread chats",
            contextMenuAction: nil,
            action: { [weak self] in self?.record("Activated catalog All Chats.") }
          )),
          animatesChanges: animationsEnabled
        )
      ),
      DeveloperSidebarCatalogFixture(
        id: "new-thread",
        title: "Navigation · New thread",
        height: standardHeight,
        configuration: .init(
          rowID: .newThread,
          content: .navigation(.init(
            title: "New thread",
            systemImage: "square.and.pencil",
            iconStyle: .newThread,
            selected: false,
            titleDimmed: true,
            size: .standard,
            prominentUnreadCount: 0,
            otherUnreadCount: 0,
            avatars: [],
            accessibilityValue: "",
            contextMenuAction: nil,
            action: { [weak self] in self?.record("Activated catalog New thread.") }
          )),
          animatesChanges: animationsEnabled
        )
      ),
      DeveloperSidebarCatalogFixture(
        id: "pinned-header",
        title: "Header · expanded",
        height: SidebarCollectionRow.spacedSectionHeaderHeight,
        configuration: .init(
          rowID: .sectionHeader(.pinned),
          content: .header(.init(
            title: "Pinned",
            style: .section,
            isExpanded: true,
            topSpacing: SidebarCollectionRow.sectionTopSpacing,
            onToggle: { [weak self] in self?.record("Activated catalog Pinned header.") },
            onCleanUp: nil,
            onCloseAll: nil
          )),
          animatesChanges: animationsEnabled
        )
      ),
      DeveloperSidebarCatalogFixture(
        id: "open-header",
        title: "Header · collapsed + cleanup",
        height: SidebarCollectionRow.spacedSectionHeaderHeight,
        configuration: .init(
          rowID: .sectionHeader(.content),
          content: .header(.init(
            title: "Open",
            style: .section,
            isExpanded: false,
            topSpacing: SidebarCollectionRow.sectionTopSpacing,
            onToggle: { [weak self] in self?.record("Activated catalog Open header.") },
            onCleanUp: { [weak self] in self?.record("Selected catalog Cleanup…") },
            onCloseAll: { [weak self] in self?.record("Selected catalog Close All.") }
          )),
          animatesChanges: animationsEnabled
        )
      ),
      DeveloperSidebarCatalogFixture(
        id: "selected-compact",
        title: "Chat · selected, compact, unread dot",
        height: compactHeight,
        configuration: chatCatalogConfiguration(.init(
          id: 3_001,
          title: "Design Feedback",
          identity: Self.userIdentity(id: 3_001, firstName: "Ava", lastName: "Lin"),
          selected: true,
          size: .compact,
          unreadCount: 1,
          prominent: true
        ), actions: noopActions)
      ),
      DeveloperSidebarCatalogFixture(
        id: "standard-numbered",
        title: "Chat · preview + numbered badge",
        height: standardHeight,
        configuration: chatCatalogConfiguration(.init(
          id: 3_002,
          title: "Engineering Alerts",
          preview: "Nadia: Build 5031 is ready to inspect",
          identity: Self.threadIdentity(emoji: "📈", title: "Engineering Alerts", isReply: false),
          unreadCount: 27,
          style: .numbered
        ), actions: noopActions)
      ),
      DeveloperSidebarCatalogFixture(
        id: "nested-reply",
        title: "Chat · nested reply + chevron",
        height: standardHeight,
        configuration: chatCatalogConfiguration(.init(
          id: 3_003,
          title: "Animation details",
          preview: "The reply stays attached to its parent",
          identity: Self.threadIdentity(emoji: nil, title: "Animation details", isReply: true),
          indentationLevel: 1,
          showsIcon: false,
          disclosureExpanded: false
        ), actions: noopActions)
      ),
      DeveloperSidebarCatalogFixture(
        id: "temporary-hover",
        title: "Chat · temporary + hover controls",
        height: standardHeight,
        configuration: chatCatalogConfiguration(.init(
          id: 3_004,
          title: "Temporary result",
          preview: "Double-click or use the menu to keep it",
          identity: Self.threadIdentity(emoji: "🧪", title: "Temporary result", isReply: false),
          showsCloseButton: true,
          isTemporary: true,
          forceHoverAppearance: true
        ), actions: noopActions)
      ),
      DeveloperSidebarCatalogFixture(
        id: "drop-target",
        title: "Chat · marked unread + drop target",
        height: standardHeight,
        configuration: chatCatalogConfiguration(.init(
          id: 3_005,
          title: "Release Room",
          preview: "Drop a file on the live collection scenario",
          identity: Self.threadIdentity(emoji: "🚀", title: "Release Room", isReply: false),
          unreadMark: true,
          isDropTargeted: true
        ), actions: noopActions)
      ),
      DeveloperSidebarCatalogFixture(
        id: "timeline",
        title: "Header · timeline",
        height: SidebarCollectionRow.timelineHeaderHeight,
        configuration: .init(
          rowID: .timelineHeader(.day(Chat.referenceDate)),
          content: .header(.init(
            title: "Today",
            style: .timeline,
            isExpanded: nil,
            topSpacing: 0,
            onToggle: nil,
            onCleanUp: nil,
            onCloseAll: nil
          )),
          animatesChanges: animationsEnabled
        )
      ),
      DeveloperSidebarCatalogFixture(
        id: "pin-guide",
        title: "Drag · empty Pinned guide",
        height: SidebarCollectionRow.emptyPinnedTargetHeight,
        configuration: .init(
          rowID: .pinDropGuide,
          content: .pinDropGuide(.init(dimsInstruction: false)),
          animatesChanges: animationsEnabled
        )
      ),
      DeveloperSidebarCatalogFixture(
        id: "empty",
        title: "Empty state · actionable",
        height: 73,
        configuration: .init(
          rowID: .emptyState,
          content: .emptyState(.init(
            title: "No chats",
            systemImage: "bubble.left",
            actionTitle: "New thread",
            action: { [weak self] in self?.record("Activated catalog empty state.") }
          )),
          animatesChanges: animationsEnabled
        )
      ),
    ]
  }

  private func chatConfiguration(
    _ projected: SidebarProjectedItem,
    context: SidebarCollectionRowRenderContext
  ) -> SidebarNativeRowConfiguration.Chat {
    let item = projected.item
    let fixture = chats.first { $0.id == item.chatId }
    return SidebarNativeRowConfiguration.Chat(
      presentation: .init(item),
      selected: selectedID == item.chatId,
      titleDimmed: false,
      size: itemSize,
      unreadBadgeStyle: unreadBadgeStyle,
      showsCloseButton: fixture?.showsCloseButton == true,
      canCloseFromSidebar: fixture?.showsCloseButton == true,
      isTemporary: fixture?.isTemporary == true,
      isDropTargeted: false,
      forceHoverAppearance: context.forceHoverAppearance,
      indentationLevel: min(projected.depth, 3),
      showsIcon: projected.showsIcon,
      disclosureExpanded: projected.isExpandable
        ? (context.disclosureExpandedOverride ?? projected.isExpanded)
        : nil,
      actions: .init(
        open: { [weak self] in self?.select(item.chatId) },
        close: { [weak self] in self?.close(item.chatId) },
        persist: { [weak self] in self?.persist(item.chatId) },
        toggleDisclosure: { [weak self] in self?.toggleParent(projected.id) },
        openInNewTab: { [weak self] in self?.record("Opened \(item.title) in a new tab.") },
        openInNewWindow: { [weak self] in self?.record("Opened \(item.title) in a new window.") },
        rename: { [weak self] in self?.record("Selected Rename for \(item.title).") },
        togglePin: { [weak self] in self?.togglePin(item.chatId) },
        toggleReadUnread: { [weak self] in self?.toggleRead(item.chatId) },
        toggleArchive: { [weak self] in self?.record("Selected Archive/Unarchive for \(item.title).") },
        folderMenu: { nil }
      )
    )
  }

  private func chatCatalogConfiguration(
    _ specification: CatalogChat,
    actions: SidebarNativeRowConfiguration.ChatActions
  ) -> SidebarNativeRowConfiguration {
    SidebarNativeRowConfiguration(
      rowID: .chat(ChatListItem.Identifier(kind: .thread, rawValue: specification.id)),
      content: .chat(.init(
        presentation: .init(
          peerID: .thread(id: specification.id),
          title: specification.title,
          preview: specification.preview,
          unread: specification.unreadCount > 0 || specification.unreadMark,
          unreadCount: specification.unreadCount,
          unreadMark: specification.unreadMark,
          prominentUnreadDot: specification.prominent,
          pinned: false,
          identity: specification.identity
        ),
        selected: specification.selected,
        titleDimmed: false,
        size: specification.size,
        unreadBadgeStyle: specification.style,
        showsCloseButton: specification.showsCloseButton,
        canCloseFromSidebar: specification.showsCloseButton,
        isTemporary: specification.isTemporary,
        isDropTargeted: specification.isDropTargeted,
        forceHoverAppearance: specification.forceHoverAppearance,
        indentationLevel: specification.indentationLevel,
        showsIcon: specification.showsIcon,
        disclosureExpanded: specification.disclosureExpanded,
        actions: actions
      )),
      animatesChanges: animationsEnabled
    )
  }

  private func navigationRow(
    id: SidebarCollectionRow.ID,
    kind: SidebarCollectionRow.Kind,
    height: CGFloat = SidebarItemSize.compact.rowHeight
  ) -> SidebarCollectionRow {
    SidebarCollectionRow(id: id, kind: kind, height: height)
  }

  private func chatRows(_ projected: [SidebarProjectedItem]) -> [SidebarCollectionRow] {
    projected.map {
      SidebarCollectionRow(
        id: .chat($0.id),
        kind: .chat($0),
        height: itemSize.rowHeight
      )
    }
  }

  private func selectedProjectedItem(
    in items: [SidebarProjectedItem]
  ) -> SidebarProjectedItem? {
    guard let selectedPeer else { return nil }
    return items.first { $0.item.peerId == selectedPeer }
  }

  private func chatTitle(_ id: Int64) -> String {
    chats.first { $0.id == id }?.title ?? "Unknown chat"
  }

  private func record(_ message: String) {
    actionLog.append(ActionEvent(id: nextActionEventID, message: message))
    nextActionEventID += 1
    if actionLog.count > 12 {
      actionLog.removeFirst(actionLog.count - 12)
    }
  }

  private static let fixtureCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }()

  private static func userIdentity(
    id: Int64,
    firstName: String,
    lastName: String
  ) -> ChatListIdentityDescriptor {
    .user(ChatListUserAvatarDescriptor(
      userID: id,
      firstName: firstName,
      lastName: lastName
    ))
  }

  private static func threadIdentity(
    emoji: String?,
    title: String,
    isReply: Bool
  ) -> ChatListIdentityDescriptor {
    .thread(ChatListThreadIconDescriptor(
      emoji: emoji,
      title: title,
      isReplyThread: isReply
    ))
  }

  private static let gridAvatars: [SidebarNativeRowConfiguration.Avatar] = [
    SidebarNativeRowConfiguration.Avatar(ChatListUserAvatarDescriptor(
      userID: 31,
      firstName: "Ava",
      lastName: "Lin"
    )),
    SidebarNativeRowConfiguration.Avatar(ChatListUserAvatarDescriptor(
      userID: 32,
      firstName: "Nadia",
      lastName: "Park"
    )),
  ]

  private static let initialChats: [Chat] = [
    Chat(
      id: 1_001,
      lane: .pinned,
      title: "Design Feedback",
      preview: "Selected pinned root — drag this row",
      identity: userIdentity(id: 1_001, firstName: "Ava", lastName: "Lin"),
      unreadCount: 0,
      unreadMark: false,
      prominent: false,
      isTemporary: false,
      showsCloseButton: true
    ),
    Chat(
      id: 1_002,
      lane: .pinned,
      title: "Product",
      preview: "Parent with an attached reply thread",
      identity: threadIdentity(emoji: "🧭", title: "Product", isReply: false),
      unreadCount: 2,
      unreadMark: false,
      prominent: true,
      isTemporary: false,
      showsCloseButton: true
    ),
    Chat(
      id: 1_003,
      lane: .pinned,
      parentChatID: 1_002,
      title: "Sidebar motion",
      preview: "Nested row, no duplicate icon",
      identity: threadIdentity(emoji: nil, title: "Sidebar motion", isReply: true),
      unreadCount: 0,
      unreadMark: true,
      prominent: false,
      isTemporary: false,
      showsCloseButton: true
    ),
    Chat(
      id: 1_101,
      lane: .normal,
      title: "Engineering Alerts",
      preview: "Nadia: Build 5031 is ready",
      identity: threadIdentity(emoji: "📈", title: "Engineering Alerts", isReply: false),
      unreadCount: 27,
      unreadMark: false,
      prominent: true,
      isTemporary: false,
      showsCloseButton: true
    ),
    Chat(
      id: 1_102,
      lane: .normal,
      title: "Taro Heartbeat",
      preview: "Boba: The badge should animate both ways",
      identity: threadIdentity(emoji: "💜", title: "Taro Heartbeat", isReply: false),
      unreadCount: 0,
      unreadMark: true,
      prominent: false,
      isTemporary: false,
      showsCloseButton: true
    ),
    Chat(
      id: 1_103,
      lane: .normal,
      title: "Temporary search result",
      preview: "Double-click to keep this row",
      identity: threadIdentity(emoji: "🧪", title: "Temporary search result", isReply: false),
      unreadCount: 0,
      unreadMark: false,
      prominent: false,
      isTemporary: true,
      showsCloseButton: true
    ),
  ]
}

struct DeveloperSidebarCatalogFixture: Identifiable {
  let id: String
  let title: String
  let height: CGFloat
  let configuration: SidebarNativeRowConfiguration
}

struct DeveloperPlaygroundSidebarView: View {
  let model: DeveloperSidebarPlaygroundModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 28) {
        DeveloperSidebarPlaygroundHeader()
        DeveloperSidebarCollectionLab(model: model)
        DeveloperSidebarRowCatalog(model: model)
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(24)
    }
    .background(Color(nsColor: .windowBackgroundColor))
  }
}

private struct DeveloperSidebarPlaygroundHeader: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("AppKit Sidebar")
        .font(.title2.weight(.semibold))
      Text("Production native rows, collection transitions, gestures, and explicit local state.")
        .foregroundStyle(.secondary)
    }
  }
}

private struct DeveloperSidebarCollectionLab: View {
  let model: DeveloperSidebarPlaygroundModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Interactive collection")
          .font(.headline)
        Text("Drag the selected Pinned row, toggle unread, repeatedly collapse sections, open menus, and resize.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      HStack(alignment: .top, spacing: 16) {
        DeveloperSidebarCollectionHost(model: model)
          .frame(width: 330, height: 500)
          .background(Color(nsColor: .controlBackgroundColor))
          .clipShape(RoundedRectangle(cornerRadius: 12))
          .overlay {
            RoundedRectangle(cornerRadius: 12)
              .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 0.5)
          }

        DeveloperSidebarActionLog(model: model)
          .frame(minWidth: 220, maxWidth: .infinity, alignment: .topLeading)
      }
    }
  }
}

private struct DeveloperSidebarCollectionHost: View {
  let model: DeveloperSidebarPlaygroundModel

  var body: some View {
    SidebarCollectionBody(
      rows: model.rows,
      tree: model.tree,
      isContentReady: true,
      reorderPolicy: .manual,
      scrollRequest: nil,
      renderState: model.renderState,
      renderer: .appKit,
      content: { _, _, _ in AnyView(EmptyView()) },
      nativeContent: { row, context in
        model.nativeConfiguration(for: row, context: context)
      },
      dragPreviewContent: { row in
        AnyView(Text(verbatim: String(describing: row.id)))
      },
      actions: SidebarCollectionActions(
        move: { move, completion in
          model.apply(move)
          completion(true)
        },
        toggleDisclosure: { id in
          guard case let .chat(chatID) = id else { return }
          model.toggleParent(chatID)
        },
        externalDropTarget: { _ in nil },
        externalDropTargetChanged: { _ in },
        performExternalDrop: { _, _ in false }
      )
    )
  }
}

private struct DeveloperSidebarActionLog: View {
  let model: DeveloperSidebarPlaygroundModel

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Deterministic actions")
        .font(.subheadline.weight(.semibold))
      ForEach(model.actionLog.suffix(9)) { event in
        Text(event.message)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
  }
}

private struct DeveloperSidebarRowCatalog: View {
  let model: DeveloperSidebarPlaygroundModel
  private let columns = [
    GridItem(.adaptive(minimum: 310), spacing: 14, alignment: .topLeading),
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Production row catalog")
          .font(.headline)
        Text("Each fixture configures SidebarNativeRowView directly; none is a SwiftUI replica.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
        ForEach(model.catalogFixtures()) { fixture in
          DeveloperSidebarCatalogCard(fixture: fixture)
        }
      }
    }
  }
}

private struct DeveloperSidebarCatalogCard: View {
  let fixture: DeveloperSidebarCatalogFixture

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(fixture.title)
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
      DeveloperSidebarNativeRowHost(configuration: fixture.configuration)
        .frame(height: fixture.height)
    }
    .padding(10)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5)
    }
  }
}

private struct DeveloperSidebarNativeRowHost: NSViewRepresentable {
  let configuration: SidebarNativeRowConfiguration

  func makeNSView(context _: Context) -> SidebarNativeRowView {
    let view = SidebarNativeRowView()
    view.configure(configuration)
    view.setLayoutVisibility(true)
    return view
  }

  func updateNSView(_ view: SidebarNativeRowView, context _: Context) {
    view.configure(configuration)
    view.setLayoutVisibility(true)
  }

  static func dismantleNSView(_ view: SidebarNativeRowView, coordinator _: Void) {
    view.prepareForReuse()
  }
}

struct DeveloperSidebarPlaygroundInspector: View {
  let model: DeveloperSidebarPlaygroundModel

  var body: some View {
    @Bindable var model = model
    Section("Sidebar scenario") {
      Picker("Layout", selection: $model.layout) {
        ForEach(DeveloperSidebarPlaygroundModel.Layout.allCases) { layout in
          Text(layout.title).tag(layout)
        }
      }
      Picker("Rows", selection: $model.itemSize) {
        ForEach(SidebarItemSize.allCases) { size in
          Text(size.rawValue.capitalized).tag(size)
        }
      }
      Picker("Unread", selection: $model.unreadBadgeStyle) {
        ForEach(UnreadBadgeStyle.allCases) { style in
          Text(style.rawValue.capitalized).tag(style)
        }
      }
      Toggle("Animations", isOn: $model.animationsEnabled)
    }

    Section("Interaction probes") {
      Button("Toggle selected unread") {
        model.toggleSelectedUnread()
      }
      .disabled(model.selectedChat == nil)

      Button("Toggle selected pin") {
        model.toggleSelectedPin()
      }
      .disabled(model.selectedChat == nil)

      Button("Insert and select new tab") {
        model.addChat()
      }

      Button(model.pinnedExpanded ? "Collapse Pinned" : "Expand Pinned") {
        model.toggleSection(.pinned)
      }

      Button(model.contentExpanded ? "Collapse Open" : "Expand Open") {
        model.toggleSection(.content)
      }

      Button("Reset fixtures") {
        model.reset()
      }
    }
  }
}
#endif
