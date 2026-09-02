import AppKit
import Auth
import Foundation
import InlineKit
import InlineMacUI
import struct InlineProtocol.GridHomeSpace
import InlineUI
import Logger
import OSLog
import RealtimeV2
import SwiftUI

private struct SidebarDropTarget {
  let peer: Peer
  let parentPeer: Peer?
}

private struct SidebarFolderRenameRequest: Identifiable {
  let id: Int64
  let title: String
  let emoji: String?
}

@MainActor
private final class SidebarDropImportJob {
  let userID: Int64?
  var task: Task<Void, Never>?

  init(userID: Int64?) {
    self.userID = userID
  }
}

struct SidebarView: View {
  private static let firstFrameDiagnostics = OSLog(
    subsystem: Bundle.main.bundleIdentifier ?? "chat.inline.InlineMac",
    category: "SidebarFirstFrame"
  )
  @Environment(\.dependencies) private var dependencies
  @Environment(\.mainWindowID) private var mainWindowID
  @Environment(\.nav) var nav
  @Environment(\.appearsActive) private var appearsActive
  @Environment(\.colorScheme) private var colorScheme
  @Environment(UnreadCountsModel.self) private var unreadCounts
  @Environment(GridRoomService.self) private var gridStore
  @EnvironmentObject private var realtimeState: RealtimeState
#if SPARKLE
  @Environment(UpdateController.self) private var updates
#endif
  @ObservedObject private var settings = AppSettings.shared
  @ObservedObject private var auth = Auth.shared
  private let audioPlayer = AudioPlaybackCenter.shared
  private let sidebarInteractionLog = Log.scoped("SidebarInteractions")
  @State private var isHomeHovering = false
  @State private var isLocationHovering = false
  @State private var isArchiveVisible = false
  @State private var showConnectedState = false
  @State private var hideConnectedTask: Task<Void, Never>?
  @State private var pendingSpaceAction: SidebarSpacePendingAction?
  @State private var sidebarRenameItem: SidebarViewModel.Item?
  @State private var sidebarRenameFolder: SidebarFolderRenameRequest?
  @State private var sidebarDrag = SidebarDragViewModel()
  @State private var cleanupOwnerID = UUID()
  @State private var visibleSidebarItemIDs = Set<ChatListItem.Identifier>()
  @State private var hasMeasuredSidebarViewport = false
  @State private var lastSidebarItemAboveViewportID: ChatListItem.Identifier?
  @State private var firstSidebarItemBelowViewportID: ChatListItem.Identifier?
  @State private var activeDropImportJobs: [UUID: SidebarDropImportJob] = [:]
  @State private var appKitExternalDropTargetID: ChatListItem.Identifier?
  @State private var appKitExternalDropGeneration = UUID()
  @State private var appKitScrollRequest: SidebarCollectionScrollRequest?
  @State private var appKitScrollRequestToken = 0
  @State private var collapsedAppKitThreadParentIDs = Set<ChatListItem.Identifier>()
  @State private var collapsedAppKitFolderIDs = Set<Int64>()
  @State private var collapsedAppKitSections = Set<SidebarCollectionRow.SectionHeader>()
  @State private var detachedAppKitReplyIDs = Set<ChatListItem.Identifier>()
  @State private var pendingClosedSidebarItemIDs = Set<ChatListItem.Identifier>()
  @State private var pendingRemovedFolderIDs = Set<Int64>()
  @State private var appKitPresentationStateUserID: Int64?
  @Environment(SidebarViewModel.self) private var viewModel
  private let isCollapsed: Bool

  init(isCollapsed: Bool = false) {
    self.isCollapsed = isCollapsed
    // Presentation state affects structural row membership, so restore it
    // before the collection's first row construction. Loading it from the
    // initial auth `onChange` produced one known-wrong expanded scene first.
    let userID = Auth.shared.getCurrentUserId()
    let store = SidebarPresentationStateStore()
    _appKitPresentationStateUserID = State(initialValue: userID)
    _detachedAppKitReplyIDs = State(initialValue: store.detachedReplyIDs(userID: userID))
    _collapsedAppKitThreadParentIDs = State(initialValue: store.collapsedParentIDs(userID: userID))
    _collapsedAppKitFolderIDs = State(initialValue: store.collapsedFolderIDs(userID: userID))
    _collapsedAppKitSections = State(initialValue: store.collapsedSections(userID: userID))
  }

  var body: some View {
    sidebarContent
      .commandBar(id: "sidebar-grid", value: gridDestinationSpaceID) {
        if let spaceID = gridDestinationSpaceID {
          CommandBarAction(
            String(localized: "Grid", comment: "Command-K action that opens Grid."),
            systemImage: "square.grid.2x2",
            id: "open-grid",
            keywords: ["grid", "voice", "room", "call"],
            typeLabel: "Navigation",
            priority: 25
          ) {
            openGrid(spaceID: spaceID)
          }
        }
      }
      .alert(
        pendingSpaceAction?.action.title ?? "Confirm",
        isPresented: spaceConfirmationPresented,
        presenting: pendingSpaceAction
      ) { pending in
        Button("Cancel", role: .cancel) {
          pendingSpaceAction = nil
        }

        Button(pending.action.shortTitle, role: .destructive) {
          performSpaceAction(pending)
        }
      } message: { pending in
        Text(pending.action.confirmationMessage(spaceName: pending.space.displayName))
      }
      .sheet(item: $sidebarRenameItem) { item in
        RenameChatSheet(peer: item.peerId, initialTitle: item.title)
      }
      .sheet(item: $sidebarRenameFolder) { folder in
        RenameSidebarFolderSheet(
          initialTitle: folder.title,
          initialEmoji: folder.emoji
        ) { title, emoji in
          renameFolder(folder.id, title: title, emoji: emoji)
        }
      }
  }

  @ViewBuilder
  private var sidebarContent: some View {
    ScrollViewReader { scrollProxy in
      if #available(macOS 26.0, *) {
        // Safe area bar gives us the natural progressive blur background on macOS 26.0
        list
          .safeAreaBar(edge: .top) {
            topBar
          }
          .safeAreaBar(edge: .bottom) {
            bottomBar(scrollProxy: scrollProxy)
          }
      } else {
        list
          .safeAreaInset(edge: .top) {
            topBar
          }
          .safeAreaInset(edge: .bottom) {
            bottomBar(scrollProxy: scrollProxy)
          }
      }
    }
  }

  private var sidebarTint: Color {
    _ = settings.themeRevision
    return Color(nsColor: Theme.sidebarOverlayColor)
  }

  private var spaceConfirmationPresented: Binding<Bool> {
    Binding {
      pendingSpaceAction != nil
    } set: { isPresented in
      if isPresented == false {
        pendingSpaceAction = nil
      }
    }
  }

  @ViewBuilder
  private var list: some View {
    appKitList
    .contentMargins(.top, 0, for: .scrollContent)
    .background(sidebarTint)
    .animation(.easeInOut(duration: 0.18), value: settings.sidebarGlassAndTintEnabled)
    .toolbar(removing: .sidebarToggle)
    .onChange(of: nav.currentRoute) { _, route in
      dependencies?.nav3ChatOpenPreloader?.cancelPendingOpenIfNeeded(for: route)
    }
    .onChange(of: selectedPeer, initial: true) { _, _ in
      viewModel.setTemporaryPeer(preferredTemporarySidebarPeer)
      revealCurrentSidebarSelectionInHierarchy()
    }
    .onChange(of: nav.selectedSpaceId, initial: true) { oldSpaceId, spaceId in
      if oldSpaceId != spaceId {
        resetSidebarVisibility()
        appKitExternalDropGeneration = UUID()
      }
      syncUnreadCountsScope(spaceId: spaceId)
      syncSource(spaceId: spaceId)
      if let spaceId {
        Task { await gridStore.load(spaceID: spaceId) }
      } else {
        Task { await gridStore.loadHome() }
      }
    }
    .onChange(of: settings.sidebarMode, initial: true) { _, mode in
      resetSidebarVisibility()
      if mode == .inbox {
        isArchiveVisible = false
      }
      sidebarDrag.cancel()
      syncSource(spaceId: nav.selectedSpaceId)
      refreshSidebarCleanup()
    }
    .onChange(of: auth.currentUserId, initial: true) { oldUserID, userID in
      if oldUserID != userID {
        cancelSidebarDropImports()
        pendingClosedSidebarItemIDs.removeAll()
        pendingRemovedFolderIDs.removeAll()
      }
      settings.resolveSidebarModeForCurrentAccount()
      appKitExternalDropGeneration = UUID()
      syncAppKitPresentationState(userID: userID)
    }
    .onChange(of: auth.status) { _, status in
      if case .loggingOut = status {
        cancelSidebarDropImports()
      }
    }
    .onChange(of: settings.includeSpaceChatsInHomeSidebar, initial: true) { _, includeSpaceChats in
      syncUnreadCountsScope(spaceId: nav.selectedSpaceId, includeSpaceChatsInHome: includeSpaceChats)
      viewModel.setIncludeSpaceChatsInHome(includeSpaceChats)
    }
    .onChange(of: effectiveSidebarSort, initial: true) { _, sortMode in
      viewModel.setSortMode(sortMode)
    }
    .onChange(of: settings.sidebarCleanupInterval, initial: true) { _, _ in
      refreshSidebarCleanup()
    }
    .onChange(of: cleanupPreconditionSnapshot, initial: true) { _, _ in
      refreshSidebarCleanup()
    }
    .onChange(of: sourceVisibleItems.map(\.id)) { _, _ in
      prunePendingSidebarCloses()
      pruneVisibleSidebarItems()
      revealCurrentSidebarSelectionInHierarchy()
    }
    .onChange(of: viewModel.folders.map(\.id)) { _, folderIDs in
      pendingRemovedFolderIDs.formIntersection(folderIDs)
    }
    .onChange(of: dependencies?.nav3?.currentReplyThreadPeer, initial: true) { _, _ in
      viewModel.setTemporaryPeer(preferredTemporarySidebarPeer)
      revealCurrentSidebarSelectionInHierarchy()
    }
    .onChange(of: viewModel.spaces.map(\.id)) { _, _ in
      validateSelectedSpace()
    }
    .onChange(of: viewModel.hasResolvedSpaces, initial: true) { _, resolved in
      guard resolved else { return }
      validateSelectedSpace()
    }
    .onChange(of: showsGridRow, initial: true) { oldValue, newValue in
      os_log(
        .info,
        log: Self.firstFrameDiagnostics,
        "component=swiftui event=grid-membership old=%{public}d new=%{public}d",
        oldValue ? 1 : 0,
        newValue ? 1 : 0
      )
    }
    .onAppear {
      unreadCounts.start()
      syncUnreadCountsScope(spaceId: nav.selectedSpaceId)
      handleRealtimeConnectionStateChange(realtimeState.connectionState)
      refreshSidebarCleanup()
    }
    .onChange(of: sidebarNavigationSignature, initial: true) { _, _ in
      registerSidebarNavigation()
    }
    .onChange(of: realtimeState.connectionState) { _, state in
      handleRealtimeConnectionStateChange(state)
    }
    .onEscapeKey("swiftui_sidebar_archive_escape", enabled: isArchiveVisible) {
      isArchiveVisible = false
    }
    .onDisappear {
      cancelSidebarDropImports()
      sidebarDrag.cancel()
      hideConnectedTask?.cancel()
      hideConnectedTask = nil
      resetSidebarVisibility()
      deactivateSidebarCleanup()
      unregisterSidebarNavigation()
    }
  }

  private var legacyList: some View {
    List {
      if settings.sidebarAsInbox {
        allChatsRow
      }

      if showsGridRow {
        gridSidebarRow
        .listRowInsets(.zero)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .padding(.bottom, SidebarSeparatorRow.totalHeight)
        .overlay(alignment: .bottom) {
          SidebarSeparatorRow()
        }
      }

      if isArchiveVisible {
        Section("Archived") {
          chatRows
        }
      } else {
        chatRows
      }
    }
  }

  private var appKitList: some View {
    let tree = appKitSidebarTree
    return SidebarCollectionBody(
      rows: makeAppKitRows(tree: tree),
      tree: tree,
      isContentReady: viewModel.isReady(
        selectedSpaceId: nav.selectedSpaceId,
        mode: settings.sidebarAsInbox ? .inbox : .chatList
      ),
      reorderPolicy: effectiveSidebarSort == .recentActivity ? .pinningOnly : .manual,
      scrollRequest: appKitScrollRequest,
      renderState: appKitRenderState,
      renderer: .appKit,
      content: appKitContent,
      nativeContent: nativeAppKitContent,
      dragPreviewContent: appKitDragPreviewContent,
      actions: SidebarCollectionActions(
        move: applyAppKitSidebarMove,
        toggleDisclosure: toggleAppKitNode,
        externalDropTarget: makeAppKitExternalDropTarget,
        externalDropTargetChanged: { appKitExternalDropTargetID = $0 },
        performExternalDrop: performAppKitExternalDrop
      )
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var appKitRenderState: SidebarCollectionRenderState {
    SidebarCollectionRenderState(
      selectedPeer: selectedPeer,
      selectedReplyPeer: dependencies?.nav3?.currentReplyThreadPeer,
      allChatsSelected: nav.currentRoute == .allChats || nav.currentRoute == .archivedChats,
      gridSelectionKey: "\(String(describing: nav.currentRoute))|\(nav.selectedSpaceId ?? 0)",
      titlesDimmed: sidebarTitlesDimmed,
      scopedProminentUnreadCount: unreadCounts.scopedUnopenedProminentUnreadCount,
      scopedOtherUnreadCount: unreadCounts.scopedUnopenedOtherUnreadCount,
      homeGridAvatarIDs: homeGridAvatars.map(\.id),
      sidebarAsInbox: settings.sidebarAsInbox,
      archiveVisible: isArchiveVisible,
      externalDropTargetID: appKitExternalDropTargetID,
      preview: SidebarCollectionRenderState.Preview(
        renderer: .appKit,
        itemSize: settings.sidebarItemSize.rawValue,
        unreadBadgeStyle: settings.unreadBadgeStyle.rawValue,
        colorScheme: String(describing: colorScheme),
        themeRevision: settings.themeRevision,
        temporaryItemID: visibleTemporaryItem?.id
      )
    )
  }

  private var appKitRows: [SidebarCollectionRow] {
    makeAppKitRows(tree: appKitSidebarTree)
  }

  private func makeAppKitRows(
    tree: SidebarCollectionTree?
  ) -> [SidebarCollectionRow] {
    var rows: [SidebarCollectionRow] = []
    let chatRowHeight = settings.sidebarItemSize.rowHeight
    let navigationRowHeight = SidebarItemSize.compact.rowHeight

    if settings.sidebarAsInbox {
      rows.append(SidebarCollectionRow(
        id: .allChats,
        kind: .allChats,
        height: navigationRowHeight
      ))
    }

    if showsGridRow {
      rows.append(SidebarCollectionRow(
        id: .grid,
        kind: .grid,
        height: navigationRowHeight
      ))
    }

    let configuration = sidebarPresentationConfiguration
    if configuration.newThreadPlacement == .beforeContent,
       settings.sidebarAsInbox == false,
       isArchiveVisible == false {
      rows.append(SidebarCollectionRow(
        id: .newThread,
        kind: .newThread,
        height: navigationRowHeight
      ))
    }

    let projectedNodes = tree?.projectedNodes() ?? []
    let pinnedNodes = projectedNodes.filter { $0.lane == .pinned }
    let contentNodes = projectedNodes.filter { $0.lane == .normal }
    let presentsPinnedSpacer = sectionUsesPinnedSpacer(.pinned)
    // The simplified Inbox keeps Pinned untitled and expanded. Its stored
    // disclosure state and titled renderer remain intact for a quick reversal.
    let pinnedExpanded = presentsPinnedSpacer
      || configuration.sectionHeaders.pinned == false
      || collapsedAppKitSections.contains(.pinned) == false
    let presentsOpenSeparator = settings.sidebarAsInbox && isArchiveVisible == false
    // Open is intentionally non-collapsible in the current presentation. Keep
    // the stored disclosure state intact so the old behavior can be restored
    // without a migration or a second source of truth.
    let contentExpanded = presentsOpenSeparator
      || configuration.sectionHeaders.content == false
      || collapsedAppKitSections.contains(.content) == false
    let isAllChatsMode = settings.sidebarAsInbox == false && isArchiveVisible == false

    if pinnedNodes.isEmpty == false {
      rows.append(.sectionHeader(
        .pinned,
        isExpanded: pinnedExpanded,
        height: presentsPinnedSpacer
          ? SidebarCollectionRow.pinnedSpacerHeight
          : (configuration.sectionHeaders.pinned
            ? SidebarCollectionRow.pinnedSectionHeaderHeight
            : 0)
      ))
      if pinnedExpanded {
        appendAppKitRows(pinnedNodes, to: &rows)
      } else if let selectedItem = selectedAppKitItem(
        in: pinnedNodes.compactMap(\.projectedItem)
      ) {
        appendAppKitChatRows([selectedItem], to: &rows)
      }
    }
    if isAllChatsMode {
      rows.append(contentsOf: SidebarCollectionRow.timelineRows(
        contentNodes.compactMap(\.projectedItem),
        chatRowHeight: chatRowHeight
      ))
    } else {
      rows.append(.sectionHeader(
        .content,
        isExpanded: contentExpanded,
        height: presentsOpenSeparator
          ? (contentNodes.isEmpty ? 0 : SidebarCollectionRow.openSeparatorHeight)
          : (configuration.sectionHeaders.content
            ? SidebarCollectionRow.spacedSectionHeaderHeight
            : 0)
      ))
    }
    if contentExpanded, isAllChatsMode == false {
      if isArchiveVisible, shouldShowEmptyState {
        rows.append(SidebarCollectionRow(
          id: .emptyState,
          kind: .emptyState,
          height: chatRowHeight
        ))
      } else {
        if configuration.newThreadPlacement == .beforeContent,
           settings.sidebarAsInbox,
           isArchiveVisible == false {
          rows.append(SidebarCollectionRow(
            id: .newThread,
            kind: .newThread,
            height: chatRowHeight
          ))
        }
        appendAppKitRows(contentNodes, to: &rows)
      }
    } else if isAllChatsMode == false,
              let selectedItem = selectedAppKitItem(
                in: contentNodes.compactMap(\.projectedItem)
              ) {
      appendAppKitChatRows([selectedItem], to: &rows)
    }

    if configuration.newThreadPlacement == .afterContent,
       settings.sidebarAsInbox,
       isArchiveVisible || contentExpanded,
       isArchiveVisible == false {
      rows.append(SidebarCollectionRow(
        id: .newThread,
        kind: .newThread,
        height: chatRowHeight
      ))
    }

    return rows
  }

  private var sidebarPresentationConfiguration: SidebarPresentationConfiguration {
    if isArchiveVisible { return .archived }
    if settings.sidebarAsInbox { return .inbox(openPlacement: openChatPlacement) }
    return .allChats
  }

  /// Keep the active destination reachable when its app-owned section is
  /// collapsed. A reply pane is the most specific active destination, so it
  /// wins over its parent chat when both peers are present in the same lane.
  private func selectedAppKitItem(
    in items: [SidebarProjectedItem]
  ) -> SidebarProjectedItem? {
    if let replyPeer = dependencies?.nav3?.currentReplyThreadPeer,
       let replyItem = items.first(where: { $0.item.peerId == replyPeer }) {
      return replyItem
    }
    guard let selectedPeer else { return nil }
    return items.first { $0.item.peerId == selectedPeer }
  }

  private func appendAppKitChatRows(
    _ items: [SidebarProjectedItem],
    to rows: inout [SidebarCollectionRow]
  ) {
    for item in items {
      rows.append(SidebarCollectionRow(
        id: .chat(item.id),
        kind: .chat(item),
        height: settings.sidebarItemSize.rowHeight
      ))
    }
  }

  private func appendAppKitRows(
    _ nodes: [SidebarProjectedNode],
    to rows: inout [SidebarCollectionRow]
  ) {
    for node in nodes {
      switch node {
      case let .chat(item):
        rows.append(SidebarCollectionRow(
          id: .chat(item.id),
          kind: .chat(item),
          height: settings.sidebarItemSize.rowHeight
        ))
      case let .folder(folder):
        rows.append(SidebarCollectionRow(
          id: .folder(folder.id),
          kind: .folder(folder),
          height: settings.sidebarItemSize.rowHeight
        ))
        if folder.childCount == 0, folder.isExpanded {
          rows.append(SidebarCollectionRow(
            id: .folderEmpty(folder.id),
            kind: .folderEmpty(folder.id, lane: folder.lane),
            height: settings.sidebarItemSize.rowHeight
          ))
        }
      }
    }
  }

  private func appKitContent(
    for row: SidebarCollectionRow,
    context: SidebarCollectionRowRenderContext,
    hostState: SidebarCollectionRowHostState? = nil
  ) -> AnyView {
    let content: AnyView = switch row.kind {
    case .allChats:
      AnyView(allChatsRow(usesFullWidthCollectionLayout: true))
    case .grid:
      AnyView(gridSidebarRow(usesFullWidthCollectionLayout: true))
    case .archiveHeader:
      AnyView(
        Text("Archived")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
          .padding(.horizontal, Theme.sidebarItemOuterSpacing)
          .padding(.bottom, 4)
      )
    case let .sectionHeader(section, isExpanded):
      AnyView(appKitSectionHeader(
        section,
        isExpanded: context.disclosureExpandedOverride ?? isExpanded,
        hostState: context.disclosureExpandedOverride == nil ? hostState : nil
      ))
    case let .timelineHeader(period):
      AnyView(SidebarCollectionTimelineHeaderView(
        title: ChatListTimelinePeriodTitle.string(
          for: period,
          calendar: .autoupdatingCurrent
        )
      ))
    case .pinDropGuide:
      AnyView(SidebarCollectionPinDropGuideView(
        dimsInstruction: context.dimsPinDropInstruction
      ))
    case let .chat(item):
      AnyView(appKitChatRow(
        item,
        disclosureExpandedOverride: context.disclosureExpandedOverride
      ))
    case let .folder(folder):
      AnyView(appKitFolderRow(
        folder,
        isDropTargeted: context.isDropTargeted,
        disclosureExpandedOverride: context.disclosureExpandedOverride
      ))
    case .folderEmpty:
      AnyView(SidebarFolderEmptyRow(size: settings.sidebarItemSize))
    case .newThread:
      AnyView(newThreadRow(usesFullWidthCollectionLayout: true))
    case .emptyState:
      AnyView(emptyStateRow)
    }

    return AnyView(
      content
        .environment(\.dependencies, dependencies)
        .environment(\.nav, nav)
        .environment(\.colorScheme, colorScheme)
        .tint(Color(nsColor: Theme.accentColor))
    )
  }

  private func nativeAppKitContent(
    for row: SidebarCollectionRow,
    context: SidebarCollectionRowRenderContext
  ) -> SidebarNativeRowConfiguration {
    let content: SidebarNativeRowConfiguration.Content = switch row.kind {
    case .allChats:
      .navigation(SidebarNativeRowConfiguration.Navigation(
        title: "All Chats",
        systemImage: "text.bubble",
        iconStyle: .standard,
        selected: nav.currentRoute == .allChats || nav.currentRoute == .archivedChats,
        titleDimmed: sidebarTitlesDimmed,
        size: .compact,
        prominentUnreadCount: unreadCounts.scopedUnopenedProminentUnreadCount,
        otherUnreadCount: unreadCounts.scopedUnopenedOtherUnreadCount,
        avatars: [],
        accessibilityValue: nativeAllChatsUnreadAccessibilityValue,
        contextMenuAction: nil,
        action: openAllChats
      ))
    case .grid:
      .navigation(SidebarNativeRowConfiguration.Navigation(
        title: "Grid",
        systemImage: "square.grid.2x2",
        iconStyle: .standard,
        selected: nativeGridIsSelected,
        titleDimmed: sidebarTitlesDimmed,
        size: .compact,
        prominentUnreadCount: 0,
        otherUnreadCount: 0,
        avatars: nativeGridAvatars.map(SidebarNativeRowConfiguration.Avatar.init),
        accessibilityValue: "",
        contextMenuAction: SidebarNativeRowConfiguration.NavigationContextMenuAction(
          title: String(localized: "Hide Grid", comment: "Context-menu action that hides Grid from the sidebar."),
          systemImage: "eye.slash",
          action: hideGridFromSidebar
        ),
        action: nativeGridAction
      ))
    case .archiveHeader:
      .header(SidebarNativeRowConfiguration.Header(
        title: "Archived",
        style: .archive,
        isExpanded: nil,
        topSpacing: 0,
        onToggle: nil,
        onCleanUp: nil,
        onCloseAll: nil
      ))
    case let .sectionHeader(section, isExpanded):
      .header(nativeSectionHeaderConfiguration(
        section,
        isExpanded: context.disclosureExpandedOverride ?? isExpanded
      ))
    case let .timelineHeader(period):
      .header(SidebarNativeRowConfiguration.Header(
        title: ChatListTimelinePeriodTitle.string(
          for: period,
          calendar: .autoupdatingCurrent
        ),
        style: .timeline,
        isExpanded: nil,
        topSpacing: 0,
        onToggle: nil,
        onCleanUp: nil,
        onCloseAll: nil
      ))
    case .pinDropGuide:
      .pinDropGuide(SidebarNativeRowConfiguration.PinDropGuide(
        dimsInstruction: context.dimsPinDropInstruction
      ))
    case let .chat(projectedItem):
      .chat(nativeChatConfiguration(
        projectedItem,
        forceHoverAppearance: context.forceHoverAppearance,
        disclosureExpandedOverride: context.disclosureExpandedOverride
      ))
    case let .folder(folder):
      .folder(SidebarNativeRowConfiguration.Folder(
        presentation: .init(folder),
        titleDimmed: sidebarTitlesDimmed,
        size: settings.sidebarItemSize,
        unreadBadgeStyle: settings.unreadBadgeStyle,
        disclosureExpanded: context.disclosureExpandedOverride ?? folder.isExpanded,
        isDropTargeted: context.isDropTargeted,
        forceHoverAppearance: context.forceHoverAppearance,
        actions: .init(
          toggleDisclosure: { toggleAppKitFolder(folder.id) },
          setEmoji: { updateFolderEmoji(folder.id, emoji: $0) },
          togglePin: { toggleFolderPin(folder) },
          rename: {
            sidebarRenameFolder = SidebarFolderRenameRequest(
              id: folder.id,
              title: folder.title,
              emoji: folder.folder.emoji
            )
          },
          close: { removeFolder(folder, disposition: .closeDialogs) },
          ungroup: { removeFolder(folder, disposition: .keepDialogs) }
        )
      ))
    case .folderEmpty:
      .folderEmpty(SidebarNativeRowConfiguration.FolderEmpty(
        size: settings.sidebarItemSize
      ))
    case .newThread:
      .navigation(SidebarNativeRowConfiguration.Navigation(
        title: "New thread",
        systemImage: "square.and.pencil",
        iconStyle: .newThread,
        selected: false,
        titleDimmed: settings.sidebarAsInbox ? true : sidebarTitlesDimmed,
        size: settings.sidebarAsInbox ? settings.sidebarItemSize : .compact,
        prominentUnreadCount: 0,
        otherUnreadCount: 0,
        avatars: [],
        accessibilityValue: "",
        contextMenuAction: nil,
        action: createNewThread
      ))
    case .emptyState:
      .emptyState(SidebarNativeRowConfiguration.EmptyState(
        title: isArchiveVisible ? "No archived chats" : "No chats",
        systemImage: isArchiveVisible ? "archivebox" : "bubble.left",
        actionTitle: isArchiveVisible ? nil : "New thread",
        action: isArchiveVisible ? nil : createNewThread
      ))
    }
    return SidebarNativeRowConfiguration(
      rowID: row.id,
      content: content,
      animatesChanges: !context.suppressesAnimations
    )
  }

  private func nativeChatConfiguration(
    _ projectedItem: SidebarProjectedItem,
    forceHoverAppearance: Bool = false,
    disclosureExpandedOverride: Bool? = nil
  ) -> SidebarNativeRowConfiguration.Chat {
    let item = projectedItem.item
    let selected = selectedPeer == item.peerId
      || dependencies?.nav3?.currentReplyThreadPeer == item.peerId
    return SidebarNativeRowConfiguration.Chat(
      presentation: SidebarNativeRowConfiguration.ChatPresentation(item),
      selected: selected,
      titleDimmed: sidebarTitlesDimmed,
      size: settings.sidebarItemSize,
      unreadBadgeStyle: settings.unreadBadgeStyle,
      showsCloseButton: appKitShowsCloseButton(for: item),
      isTemporary: isTemporaryItem(item),
      isDropTargeted: appKitExternalDropTargetID == projectedItem.id,
      forceHoverAppearance: forceHoverAppearance,
      indentationLevel: min(projectedItem.depth, 3),
      showsIcon: projectedItem.showsIcon,
      disclosureExpanded: projectedItem.isExpandable
        ? (disclosureExpandedOverride ?? projectedItem.isExpanded)
        : nil,
      actions: SidebarNativeRowConfiguration.ChatActions(
        open: { openChat(item) },
        close: { closeChat(item) },
        persist: { persistTemporaryChat(item) },
        toggleDisclosure: { toggleAppKitThreadParent(projectedItem.id) },
        openInNewTab: {
          MainWindowOpenCoordinator.shared.openTab(.chat(peer: item.peerId))
        },
        openInNewWindow: {
          MainWindowOpenCoordinator.shared.openNewWindow(.chat(peer: item.peerId))
        },
        rename: { sidebarRenameItem = item },
        togglePin: { SidebarChatRowActionRunner.togglePin(item) },
        toggleReadUnread: {
          SidebarChatRowActionRunner.toggleReadUnread(
            item,
            dependencies: dependencies
          )
        },
        toggleArchive: {
          guard let dependencies else { return }
          ChatMenuActions.toggleArchive(
            peer: item.peerId,
            isArchived: item.archived,
            spaceID: item.spaceId,
            dependencies: dependencies
          )
        },
        folderMenu: { sidebarFolderMenu(for: item) }
      )
    )
  }

  private func appKitFolderRow(
    _ folder: SidebarProjectedFolder,
    isDropTargeted: Bool = false,
    disclosureExpandedOverride: Bool? = nil
  ) -> some View {
    SidebarFolderItemView(
      title: folder.title,
      emoji: folder.folder.emoji,
      childCount: folder.childCount,
      unreadCount: folder.unreadCount,
      prominentUnreadCount: folder.prominentUnreadCount,
      unreadBadgeStyle: settings.unreadBadgeStyle,
      isPinned: folder.folder.isPinned,
      isExpanded: disclosureExpandedOverride ?? folder.isExpanded,
      isDropTargeted: isDropTargeted,
      titleDimmed: sidebarTitlesDimmed,
      size: settings.sidebarItemSize,
      onToggle: { toggleAppKitFolder(folder.id) },
      onSetEmoji: { updateFolderEmoji(folder.id, emoji: $0) },
      onTogglePin: { toggleFolderPin(folder) },
      onRename: {
        sidebarRenameFolder = SidebarFolderRenameRequest(
          id: folder.id,
          title: folder.title,
          emoji: folder.folder.emoji
        )
      },
      onClose: { removeFolder(folder, disposition: .closeDialogs) },
      onUngroup: { removeFolder(folder, disposition: .keepDialogs) }
    )
    .equatable()
  }

  private var nativeGridAvatars: [InlineKit.User] {
    if let spaceID = nav.selectedSpaceId {
      return gridStore.recentAvatars(spaceID: spaceID).map { InlineKit.User(from: $0.user) }
    }
    return homeGridAvatars
  }

  private var nativeGridIsSelected: Bool {
    if let spaceID = nav.selectedSpaceId {
      return nav.currentRoute == .grid(spaceId: spaceID)
    }
    return isAnyHomeGridSelected
  }

  private var nativeGridAction: () -> Void {
    if let spaceID = nav.selectedSpaceId {
      return { openGrid(spaceID: spaceID) }
    }
    if let home = homeGridSpaces.first {
      return { openGrid(spaceID: home.spaceID) }
    }
    return {}
  }

  private func nativeSectionSupportsCleanup(
    _ section: SidebarCollectionRow.SectionHeader
  ) -> Bool {
    section == .content && settings.sidebarAsInbox && !isArchiveVisible
  }

  private func sectionUsesPinnedSpacer(
    _ section: SidebarCollectionRow.SectionHeader
  ) -> Bool {
    section == .pinned && settings.sidebarAsInbox && !isArchiveVisible
  }

  private func nativeSectionHeaderConfiguration(
    _ section: SidebarCollectionRow.SectionHeader,
    isExpanded: Bool
  ) -> SidebarNativeRowConfiguration.Header {
    let presentsOpenSeparator = nativeSectionSupportsCleanup(section)
    let presentsPinnedSpacer = sectionUsesPinnedSpacer(section)
    let isInertPresentation = presentsOpenSeparator || presentsPinnedSpacer
    let style: SidebarNativeRowConfiguration.Header.Style = if presentsOpenSeparator {
      .openSeparator
    } else if presentsPinnedSpacer {
      .pinnedSpacer
    } else {
      section == .pinned ? .pinnedSection : .section
    }
    return SidebarNativeRowConfiguration.Header(
      title: isInertPresentation
        ? ""
        : section.title(
          sidebarAsInbox: settings.sidebarAsInbox,
          archiveVisible: isArchiveVisible
        ),
      style: style,
      isExpanded: isInertPresentation ? nil : isExpanded,
      topSpacing: isInertPresentation ? 0 : SidebarCollectionRow.sectionTopSpacing,
      onToggle: isInertPresentation ? nil : { toggleAppKitSection(section) },
      onCleanUp: presentsOpenSeparator ? cleanUpOpenChats : nil,
      onCloseAll: presentsOpenSeparator ? closeAllOpenChats : nil
    )
  }

  private var nativeAllChatsUnreadAccessibilityValue: String {
    let prominent = unreadCounts.scopedUnopenedProminentUnreadCount
    let other = unreadCounts.scopedUnopenedOtherUnreadCount
    var parts: [String] = []
    if prominent > 0 {
      parts.append("\(prominent) prominent unread chat\(prominent == 1 ? "" : "s")")
    }
    if other > 0 {
      parts.append("\(other) other unread chat\(other == 1 ? "" : "s")")
    }
    return parts.isEmpty ? "" : "\(parts.joined(separator: " and ")) not in sidebar"
  }

  private func appKitDragPreviewContent(for row: SidebarCollectionRow) -> AnyView {
    guard case let .chat(projectedItem) = row.kind else {
      return appKitContent(for: row, context: .idle)
    }

    let item = projectedItem.item
    let isSelected = selectedPeer == item.peerId
      || dependencies?.nav3?.currentReplyThreadPeer == item.peerId
    return AnyView(
      SidebarChatItemView(
          item: item,
          selected: isSelected,
          titleDimmed: sidebarTitlesDimmed,
          size: settings.sidebarItemSize,
          unreadBadgeStyle: settings.unreadBadgeStyle,
          showsCloseButton: appKitShowsCloseButton(for: item),
          opensOnMouseDown: false,
          allowsHoverEffects: false,
          forceHoverAppearance: true,
          isTemporary: isTemporaryItem(item),
          isDropTargeted: false,
          indentationLevel: min(projectedItem.depth, 3),
          showsIcon: projectedItem.showsIcon,
          disclosureExpanded: projectedItem.isExpandable ? projectedItem.isExpanded : nil,
          usesFullWidthCollectionLayout: true
      )
      .equatable()
      .allowsHitTesting(false)
      .environment(\.dependencies, dependencies)
      .environment(\.nav, nav)
      .environment(\.colorScheme, colorScheme)
      .tint(Color(nsColor: Theme.accentColor))
    )
  }

  private func appKitChatRow(
    _ projectedItem: SidebarProjectedItem,
    disclosureExpandedOverride: Bool? = nil
  ) -> some View {
    let item = projectedItem.item
    let isSelected = selectedPeer == item.peerId
      || dependencies?.nav3?.currentReplyThreadPeer == item.peerId
    let isTemporary = isTemporaryItem(item)

    return SidebarChatItemView(
        item: item,
        selected: isSelected,
        titleDimmed: sidebarTitlesDimmed,
        size: settings.sidebarItemSize,
        unreadBadgeStyle: settings.unreadBadgeStyle,
        showsCloseButton: appKitShowsCloseButton(for: item),
        // Let NSCollectionView's drag recognizer win once the pointer moves;
        // a normal click still opens on mouse-up through the row tap gesture.
        opensOnMouseDown: false,
        isTemporary: isTemporary,
        isDropTargeted: appKitExternalDropTargetID == projectedItem.id,
        indentationLevel: min(projectedItem.depth, 3),
        showsIcon: projectedItem.showsIcon,
        disclosureExpanded: projectedItem.isExpandable
          ? (disclosureExpandedOverride ?? projectedItem.isExpanded)
          : nil,
        usesFullWidthCollectionLayout: true,
        onOpen: {
          openChat(item)
        },
        onClose: {
          closeChat(item)
        },
        onPersist: {
          persistTemporaryChat(item)
        },
        onToggleDisclosure: {
          toggleAppKitThreadParent(projectedItem.id)
        },
        folderMenu: { sidebarFolderMenu(for: item) }
      )
      .equatable()
      .simultaneousGesture(TapGesture(count: 2).onEnded {
        if isTemporary {
          persistTemporaryChat(item)
        }
      })
  }

  private func appKitShowsCloseButton(for item: SidebarViewModel.Item) -> Bool {
    guard settings.sidebarAsInbox else { return false }
    guard isInPinnedFolder(item) == false else { return false }
    return item.pinned == false || item.parentChatId != nil
  }

  private func isInPinnedFolder(_ item: SidebarViewModel.Item) -> Bool {
    guard let folderID = item.folderID else { return false }
    return viewModel.folders.first(where: { $0.id == folderID })?.isPinned == true
  }

  @ViewBuilder
  private func appKitSectionHeader(
    _ section: SidebarCollectionRow.SectionHeader,
    isExpanded: Bool,
    hostState: SidebarCollectionRowHostState?
  ) -> some View {
    if nativeSectionSupportsCleanup(section) {
      SidebarCollectionOpenSeparatorView(
        onCleanUp: cleanUpOpenChats,
        onCloseAll: closeAllOpenChats
      )
    } else if sectionUsesPinnedSpacer(section) {
      SidebarCollectionPinnedSpacerView()
    } else {
      SidebarCollectionSectionHeaderView(
        title: section.title(
          sidebarAsInbox: settings.sidebarAsInbox,
          archiveVisible: isArchiveVisible
        ),
        isPinned: section == .pinned,
        initialIsExpanded: isExpanded,
        hostState: hostState,
        topSpacing: SidebarCollectionRow.sectionTopSpacing,
        onToggle: { toggleAppKitSection(section) }
      )
    }
  }

  private var allChatsRow: some View {
    allChatsRow(usesFullWidthCollectionLayout: false)
  }

  private func allChatsRow(usesFullWidthCollectionLayout: Bool) -> some View {
    SidebarInboxActionRow(
      title: "All Chats",
      systemImage: "text.bubble",
      selected: nav.currentRoute == .allChats || nav.currentRoute == .archivedChats,
      titleDimmed: sidebarTitlesDimmed,
      size: .compact,
      prominentUnreadCount: unreadCounts.scopedUnopenedProminentUnreadCount,
      nonProminentUnreadCount: unreadCounts.scopedUnopenedOtherUnreadCount,
      usesFullWidthCollectionLayout: usesFullWidthCollectionLayout,
      action: openAllChats
    )
    .listRowInsets(.zero)
    .listRowSeparator(.hidden)
    .listRowBackground(Color.clear)
  }

  private var selectedSpaceGridEnabled: Bool {
    guard let spaceID = nav.selectedSpaceId else { return false }
    return gridStore.isEnabled(spaceID: spaceID)
  }

  private var showsGridRow: Bool {
    settings.showGridInSidebar && gridDestinationSpaceID != nil
  }

  private var gridDestinationSpaceID: Int64? {
    if let spaceID = nav.selectedSpaceId {
      return selectedSpaceGridEnabled ? spaceID : nil
    }
    return homeGridSpaces.first?.spaceID
  }

  @ViewBuilder
  private var gridSidebarRow: some View {
    gridSidebarRow(usesFullWidthCollectionLayout: false)
  }

  @ViewBuilder
  private func gridSidebarRow(usesFullWidthCollectionLayout: Bool) -> some View {
    if let spaceID = nav.selectedSpaceId {
      SidebarGridRow(
        avatars: gridStore.recentAvatars(spaceID: spaceID).map { InlineKit.User(from: $0.user) },
        selected: nav.currentRoute == .grid(spaceId: spaceID),
        titleDimmed: sidebarTitlesDimmed,
        size: .compact,
        usesFullWidthCollectionLayout: usesFullWidthCollectionLayout,
        hideAction: hideGridFromSidebar,
        action: { openGrid(spaceID: spaceID) }
      )
    } else if let home = homeGridSpaces.first {
      SidebarGridRow(
        avatars: homeGridAvatars,
        selected: isAnyHomeGridSelected,
        titleDimmed: sidebarTitlesDimmed,
        size: .compact,
        usesFullWidthCollectionLayout: usesFullWidthCollectionLayout,
        hideAction: hideGridFromSidebar,
        action: { openGrid(spaceID: home.spaceID) }
      )
    }
  }

  private var homeGridSpaces: [GridHomeSpace] {
    gridStore.orderedHomeSpaces
  }

  private var homeGridAvatars: [InlineKit.User] {
    var seen = Set<Int64>()
    return homeGridSpaces
      .flatMap(\.recentAvatars)
      .filter { seen.insert($0.user.id).inserted }
      .prefix(4)
      .map { InlineKit.User(from: $0.user) }
  }

  private var isAnyHomeGridSelected: Bool {
    guard case let .grid(spaceID) = nav.currentRoute else { return false }
    return homeGridSpaces.contains { $0.spaceID == spaceID }
  }

  private func openGrid(spaceID: Int64) {
    gridStore.recordGridOpened(spaceID: spaceID)
    nav.openGrid(spaceId: spaceID)
  }

  private func hideGridFromSidebar() {
    settings.showGridInSidebar = false
  }

  @ViewBuilder
  private var chatRows: some View {
    if settings.sidebarAsInbox {
      let pinnedItems = sidebarDrag.displayItems(visiblePinnedItems, lane: .pinned)
      let normalItems = sidebarDrag.displayItems(visibleNormalSourceItems, lane: .normal)

      if pinnedItems.isEmpty == false {
        chatRows(for: visiblePinnedItems, lane: .pinned)
      }

      if openChatPlacement == .top, isArchiveVisible == false {
        newThreadRow
      }

      if normalItems.isEmpty == false {
        chatRows(for: visibleNormalSourceItems, lane: .normal, showsTopSeparator: pinnedItems.isEmpty == false)
      }
    } else {
      chatRows(for: visibleItems)
    }

    if settings.sidebarAsInbox {
      if openChatPlacement == .bottom || isArchiveVisible {
        newThreadRow
      }
    } else if shouldShowEmptyState {
      emptyStateRow
    } else if !isArchiveVisible, visibleItems.isEmpty == false {
      newThreadRow
    }
  }

  @ViewBuilder
  private func chatRows(
    for items: [SidebarViewModel.Item],
    lane: SidebarOrderLane? = nil,
    showsTopSeparator: Bool = false
  ) -> some View {
    let displayItems = sidebarDrag.displayItems(items, lane: lane)

    ForEach(Array(displayItems.enumerated()), id: \.element.id) { index, item in
      let isSelected = selectedPeer == item.peerId
      let isDragging = sidebarDrag.isDragging(item, lane: lane)
      let isTemporary = isTemporaryItem(item)
      let showsSeparator = showsTopSeparator && index == displayItems.startIndex

      SidebarDropDestination(
        beginTransferDrop: {
          beginSidebarDrop(to: sidebarDropTarget(for: item))
        },
        performTransferredDrop: { transfers, importID in
          handleSidebarTransferredDrop(
            transfers,
            importID: importID,
            on: item
          )
        },
        performNativeDrop: { pasteboard in
          handleSidebarDrop(pasteboard, on: item)
        },
        content: { isDropTargeted in
          SidebarChatItemView(
            item: item,
            selected: isSelected,
            titleDimmed: sidebarTitlesDimmed,
            size: settings.sidebarItemSize,
            unreadBadgeStyle: settings.unreadBadgeStyle,
            showsCloseButton: settings.sidebarAsInbox
              && item.pinned == false
              && isInPinnedFolder(item) == false,
            opensOnMouseDown: true,
            isTemporary: isTemporary,
            isDropTargeted: isDropTargeted,
            onOpen: {
              openChat(item)
            },
            onClose: {
              closeChat(item)
            },
            onPersist: {
              persistTemporaryChat(item)
            }
          )
          .equatable()
        }
      )
      .id(item.id)
      .onScrollVisibilityChange { isVisible in
        setSidebarItemVisibility(item.id, isVisible: isVisible)
      }
      .onDisappear {
        visibleSidebarItemIDs.remove(item.id)
      }
      .simultaneousGesture(TapGesture(count: 2).onEnded {
        if isTemporary {
          persistTemporaryChat(item)
        }
      })
      .modifier(SidebarFloatingReorderRowModifier(
        enabled: lane != nil,
        isDragging: isDragging,
        onDragChanged: { value, rowSize in
          updateSidebarDrag(
            item: item,
            lane: lane,
            items: items,
            value: value,
            rowSize: rowSize
          )
        },
        onDragEnded: {
          endSidebarDrag()
        }
      ))
      .listRowInsets(.zero)
      .listRowSeparator(.hidden)
      .listRowBackground(Color.clear)
      .padding(.top, showsSeparator ? SidebarSeparatorRow.totalHeight : 0)
      .overlay(alignment: .top) {
        if showsSeparator {
          SidebarSeparatorRow()
        }
      }
      .transition(.opacity.combined(with: .move(edge: .top)))
    }
  }

  private var emptyStateRow: some View {
    SidebarEmptyStateRow(
      title: isArchiveVisible ? "No archived chats" : "No chats",
      systemImage: isArchiveVisible ? "archivebox" : "bubble.left",
      actionTitle: isArchiveVisible ? nil : "New thread",
      action: isArchiveVisible ? nil : createNewThread
    )
    .listRowInsets(.zero)
    .listRowSeparator(.hidden)
    .listRowBackground(Color.clear)
    .transition(.opacity.combined(with: .move(edge: .bottom)))
  }

  private var newThreadRow: some View {
    newThreadRow(usesFullWidthCollectionLayout: false)
  }

  private func newThreadRow(usesFullWidthCollectionLayout: Bool) -> some View {
    SidebarNewThreadRow(
      size: settings.sidebarAsInbox ? settings.sidebarItemSize : .compact,
      titleDimmed: settings.sidebarAsInbox ? true : sidebarTitlesDimmed,
      usesFullWidthCollectionLayout: usesFullWidthCollectionLayout,
      action: createNewThread
    )
    .listRowInsets(.zero)
    .listRowSeparator(.hidden)
    .listRowBackground(Color.clear)
  }

  @ViewBuilder
  private var topBar: some View {
    HStack(spacing: 2) {
      if selectedSpace != nil {
        homeButton

        Rectangle()
          .fill(Color.secondary.opacity(0.28))
          .opacity(isTopBarSeparatorHidden ? 0 : 1)
          .frame(width: 1, height: 18)
      }

      sidebarLocationMenu
    }
    // Keep the picker inside its safe-area allocation in every button/state
    // combination, and use the same section gap as the collection below.
    .padding(.bottom, SidebarCollectionRow.sectionTopSpacing)
    // side spacing visually must match the items below
    .padding(.leading, SidebarTopBarMetrics.leadingPadding)
    .padding(.trailing, Theme.sidebarItemOuterSpacing)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var homeButton: some View {
    Button(action: selectHome) {
      Image(systemName: "house")
        .resizable()
        .scaledToFit()
        .frame(width: 18, height: 18)
        .foregroundColor(.secondary)
        .frame(width: SidebarTopBarMetrics.buttonHeight, height: SidebarTopBarMetrics.buttonHeight)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(SidebarTopBarHoverBackground(isHovering: isHomeHovering))
    .overlay(alignment: .topTrailing) {
      if unreadCounts.prominentUnreadOutsideSelectedSpaceCount > 0 {
        UnreadDotBadge(prominent: true, size: 6)
          .padding(.top, 7)
          .padding(.trailing, 7)
      }
    }
    .help("Home")
    .accessibilityLabel("Home")
    .accessibilityValue(homeButtonAccessibilityValue)
    .onHover { isHomeHovering = $0 }
  }

  private var sidebarLocationMenu: some View {
    Menu {
      sidebarLocationMenuContent
    } label: {
      HStack(spacing: 10) {
        topBarIcon

        Text(topBarTitle)
          .foregroundStyle(sidebarTitleColor)
          .lineLimit(1)
          .truncationMode(.tail)
          .layoutPriority(1)
      }
      .contentShape(Rectangle())
      .padding(.horizontal, 8)
      .frame(height: SidebarTopBarMetrics.buttonHeight)
      .background(SidebarTopBarHoverBackground(isHovering: isLocationHovering))
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .focusEffectDisabled(true)
    .menuIndicator(.hidden)
    .inlineTooltip(
      "Switch space",
      placement: .cursor
    )
    .onHover { isLocationHovering = $0 }
    .contextMenu {
      if let selectedSpace {
        Section("Manage \(selectedSpace.displayName)") {
          selectedSpaceActions(selectedSpace)

          Divider()

          selectedSpaceDestructiveAction(selectedSpace)
        }
      }
    }
  }

  @ViewBuilder
  private var sidebarLocationMenuContent: some View {
    if let selectedSpace {
      Section("Manage \(selectedSpace.displayName)") {
        selectedSpaceActions(selectedSpace)
      }

      Divider()
    }

    if viewModel.spaces.isEmpty == false {
      Section("Spaces") {
        ForEach(viewModel.spaces) { space in
          Button {
            selectSpace(space.id)
          } label: {
            Label(space.displayName, systemImage: "building")
          }
        }
      }

      Divider()
    }

    Button {
      nav.open(.createSpace)
    } label: {
      Label("Create Space", systemImage: "plus")
    }
  }

  @ViewBuilder
  private func selectedSpaceActions(_ space: Space) -> some View {
    Button {
      nav.open(.spaceSettings(spaceId: space.id))
    } label: {
      Label("Settings", systemImage: "gear")
    }

    Button {
      nav.open(.members(spaceId: space.id))
    } label: {
      Label("Members", systemImage: "person.2")
    }
  }

  private func selectedSpaceDestructiveAction(_ space: Space) -> some View {
    let action = SidebarSpaceDestructiveAction.action(for: space)

    return Button(role: .destructive) {
      pendingSpaceAction = SidebarSpacePendingAction(space: space, action: action)
    } label: {
      Label(action.title, systemImage: action.systemImage)
    }
  }

  @ViewBuilder
  private func bottomBar(scrollProxy: ScrollViewProxy) -> some View {
    VStack(spacing: 3) {
      // Temporarily hide the sidebar connection indicator.
      // if let state = sidebarConnectionState {
      //   SidebarConnectionStatePill(state: state)
      //     .padding(.horizontal, Theme.sidebarItemOuterSpacing + 4)
      //     .transition(.opacity)
      // }

      if audioPlayer.item != nil {
        AudioNowPlayingPill()
          .padding(.horizontal, Theme.sidebarItemOuterSpacing + 4)
          .transition(AudioNowPlayingPill.visibilityTransition)
      }

#if SPARKLE
      if updates.showsSidebarAction {
        installUpdateButton
          .transition(.opacity)
      }
#endif

      footerBar
    }
    .animation(.smoothSnappy, value: sidebarConnectionState)
    .animation(AudioNowPlayingPill.visibilityAnimation, value: audioPlayer.item)
#if SPARKLE
    .animation(.smoothSnappy, value: updates.showsSidebarAction)
#endif
  }

  @ViewBuilder
  private var footerBar: some View {
    SidebarFooterView(
      isArchiveActive: isArchiveVisible,
      showsArchive: settings.sidebarAsInbox == false,
      itemSize: $settings.sidebarItemSize,
      sortMode: $settings.sidebarSort,
      cleanupInterval: $settings.sidebarCleanupInterval,
      sidebarMode: $settings.sidebarMode,
      onToggleArchive: {
        guard settings.sidebarAsInbox == false else { return }
        isArchiveVisible.toggle()
      },
      onSearch: {
        nav.openCommandBar()
      },
      onCreateSpace: {
        nav.open(.createSpace)
      },
      onNewFolder: canCreateFolder ? createEmptyFolder : nil,
      onNewThread: {
        createNewThread()
      },
      onInvite: {
        nav.beginInvite(spaceId: activeSpaceId)
      },
      onOpenDocs: openDocs,
      onOpenTownHall: openTownHall,
      onDMFounder: dmFounder,
      onCheckForUpdates: checkForUpdatesAction,
      onOpenWhatsNew: openWhatsNew,
      onOpenStatus: openStatus
    )
  }

  private var checkForUpdatesAction: (() -> Void)? {
#if SPARKLE
    { updates.checkForUpdates() }
#else
    nil
#endif
  }

  @ViewBuilder
  private var installUpdateButton: some View {
#if SPARKLE
    let button = Button {
      updates.performPrimaryAction()
    } label: {
      Text("Update Inline")
        .font(.system(size: 13, weight: .semibold))
        .padding(.horizontal, 10)
    }
    .controlSize(.large)
    .buttonBorderShape(.capsule)
    .overlay {
      ButtonShineOverlay(active: true)
    }
    .clipShape(Capsule())

    if #available(macOS 26.0, *) {
      button
        .buttonStyle(.glassProminent)
    } else {
      button
        .buttonStyle(.borderedProminent)
    }
#endif
  }

  @ViewBuilder
  private var topBarIcon: some View {
    if let space = selectedSpace {
      SpaceAvatar(space: space, size: 18)
    } else {
      Image(systemName: "house")
        .resizable()
        .scaledToFit()
        .frame(width: 18, height: 18)
        .foregroundColor(.secondary)
    }
  }

  private var topBarTitle: String {
    selectedSpace?.displayName ?? "Home"
  }

  private var activeSpaceId: Int64? {
    nav.selectedSpaceId
  }

  private var selectedSpace: Space? {
    viewModel.space(id: nav.selectedSpaceId)
  }

  /// The reply pane is the most specific visible route. Keeping it in the
  /// read-only temporary slot makes pane opening deterministic while the
  /// dialog-open transaction catches up, instead of waiting for DB ordering.
  private var preferredTemporarySidebarPeer: Peer? {
    dependencies?.nav3?.currentReplyThreadPeer ?? selectedPeer
  }

  private var sourceVisibleItems: [SidebarViewModel.Item] {
    isArchiveVisible ? viewModel.archivedItems : viewModel.activeItems
  }

  private var visibleItems: [SidebarViewModel.Item] {
    sourceVisibleItems.filter { pendingClosedSidebarItemIDs.contains($0.id) == false }
  }

  private var visiblePinnedItems: [SidebarViewModel.Item] {
    visibleItems.filter(\.pinned)
  }

  private var visibleNormalItems: [SidebarViewModel.Item] {
    visibleItems.filter { $0.pinned == false }
  }

  private var visibleNormalSourceItems: [SidebarViewModel.Item] {
    switch openChatPlacement {
    case .top:
      visibleTemporaryItems + visibleNormalItems
    case .bottom:
      visibleNormalItems + visibleTemporaryItems
    }
  }

  private var openChatPlacement: DialogOpenPlacement {
    .defaultValue
  }

  private var sidebarOrderedItems: [SidebarViewModel.Item] {
    guard isArchiveVisible == false else { return [] }

    return appKitProjectedVisibleItems.map(\.item)
  }

  private var appKitSidebarProjectedItems: [SidebarProjectedItem] {
    appKitSidebarTree.projectedItems()
  }

  private var appKitSidebarTree: SidebarCollectionTree {
    SidebarCollectionProjection.sidebarTree(
      pinnedItems: visiblePinnedItems,
      normalItems: visibleNormalSourceItems,
      folders: foldersPresentedInCurrentSidebar,
      collapsedParentIDs: collapsedAppKitThreadParentIDs,
      collapsedFolderIDs: collapsedAppKitFolderIDs,
      detachedReplyIDs: detachedAppKitReplyIDs,
      nestingPolicy: sidebarPresentationConfiguration.nesting,
      sortMode: effectiveSidebarSort
    )
  }

  private var foldersPresentedInCurrentSidebar: [SidebarViewModel.Folder] {
    let folders = viewModel.folders.filter {
      pendingRemovedFolderIDs.contains($0.id) == false
    }
    return settings.sidebarMode == .allChats ? folders.filter(\.isPinned) : folders
  }

  private var appKitProjectedVisibleItems: [SidebarProjectedItem] {
    appKitSidebarProjectedItems.filter { projectedItem in
      switch projectedItem.lane {
      case .pinned:
        collapsedAppKitSections.contains(.pinned) == false
      case .normal:
        collapsedAppKitSections.contains(.content) == false
      case nil:
        true
      }
    }
  }

  private var effectiveSidebarSort: SidebarSortMode {
    settings.sidebarMode == .allChats ? .recentActivity : settings.sidebarSort
  }

  private func toggleAppKitThreadParent(_ id: ChatListItem.Identifier) {
    let visibleRowsBefore = appKitRows.count
    let expanded: Bool
    if collapsedAppKitThreadParentIDs.remove(id) == nil {
      collapsedAppKitThreadParentIDs.insert(id)
      expanded = false
    } else {
      expanded = true
    }
    persistCollapsedAppKitThreadParentIDs()
    sidebarInteractionLog.info(
      "collapse parent expanded=\(expanded) visibleRowsBefore=\(visibleRowsBefore) "
        + "visibleRowsAfter=\(appKitRows.count)"
    )
  }

  private func toggleAppKitNode(_ id: SidebarCollectionNodeID) {
    switch id {
    case let .chat(chatID):
      toggleAppKitThreadParent(chatID)
    case let .folder(folderID):
      toggleAppKitFolder(folderID)
    }
  }

  private func toggleAppKitFolder(_ id: Int64) {
    let visibleRowsBefore = appKitRows.count
    let expanded: Bool
    if collapsedAppKitFolderIDs.remove(id) == nil {
      collapsedAppKitFolderIDs.insert(id)
      expanded = false
    } else {
      expanded = true
    }
    persistCollapsedAppKitFolderIDs()
    sidebarInteractionLog.info(
      "collapse folder expanded=\(expanded) visibleRowsBefore=\(visibleRowsBefore) "
        + "visibleRowsAfter=\(appKitRows.count)"
    )
  }

  private func sidebarFolderMenu(
    for item: SidebarViewModel.Item
  ) -> SidebarChatFolderMenu? {
    guard isArchiveVisible == false,
          nav.selectedSpaceId == nil,
          isTemporaryItem(item) == false
    else { return nil }

    let destinations = foldersPresentedInCurrentSidebar
      .filter { folder in
        folder.id != item.folderID
      }
      .map { folder in
        let title = folder.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return SidebarChatFolderMenu.Destination(
          id: folder.id,
          title: title.flatMap { $0.isEmpty ? nil : $0 } ?? "New Folder",
          move: { moveChat(item, toFolder: folder.id) }
        )
      }
    return SidebarChatFolderMenu(
      destinations: destinations,
      create: { createFolder(containing: item) },
      removeFromFolder: item.folderID == nil ? nil : { moveChatToRoot(item) }
    )
  }

  private func createFolder(containing item: SidebarViewModel.Item) {
    createFolder(peers: [item.peerId])
  }

  private func createEmptyFolder() {
    createFolder(peers: [])
  }

  private func createFolder(peers: [Peer]) {
    guard let dependencies else { return }
    let pinnedOrder = settings.sidebarMode == .allChats ? nextSidebarPinnedOrder() : nil
    Task(priority: .userInitiated) {
      do {
        _ = try await dependencies.realtimeV2.send(.createDialogFolder(
          title: nil,
          peers: peers,
          pinnedOrder: pinnedOrder
        ))
      } catch {
        sidebarInteractionLog.error("folder creation failed", error: error)
        ToastCenter.shared.showError("Couldn’t create the folder. Please try again.")
      }
    }
  }

  private var canCreateFolder: Bool {
    isArchiveVisible == false && nav.selectedSpaceId == nil
  }

  private func moveChat(_ item: SidebarViewModel.Item, toFolder folderID: Int64) {
    persistFolderMembership(item, destination: .folder(folderID))
  }

  private func moveChatToRoot(_ item: SidebarViewModel.Item) {
    persistFolderMembership(item, destination: .root)
  }

  private func persistFolderMembership(
    _ item: SidebarViewModel.Item,
    destination: DialogOrderDestination
  ) {
    guard let dependencies else { return }
    let pinned: Bool?
    switch destination {
    case .root: pinned = false
    case .folder: pinned = nil
    }
    Task(priority: .userInitiated) {
      do {
        _ = try await dependencies.realtimeV2.send(.updateDialogOrder(
          peerId: item.peerId,
          pinned: pinned,
          destination: destination
        ))
      } catch {
        sidebarInteractionLog.error("folder membership update failed", error: error)
        ToastCenter.shared.showError("Couldn’t move that chat. Please try again.")
      }
    }
  }

  private func updateFolderEmoji(_ folderID: Int64, emoji: String) {
    guard let dependencies else { return }
    Task(priority: .userInitiated) {
      do {
        _ = try await dependencies.realtimeV2.send(.updateDialogFolder(
          folderId: folderID,
          emoji: .set(emoji)
        ))
      } catch {
        sidebarInteractionLog.error("folder emoji update failed", error: error)
        ToastCenter.shared.showError("Couldn’t update the folder emoji. Please try again.")
      }
    }
  }

  private func renameFolder(_ folderID: Int64, title: String, emoji: String?) {
    guard let dependencies else { return }
    let emojiUpdate: UpdateDialogFolderTransaction.EmojiUpdate = emoji.map {
      .set($0)
    } ?? .clear
    Task(priority: .userInitiated) {
      do {
        _ = try await dependencies.realtimeV2.send(.updateDialogFolder(
          folderId: folderID,
          title: .set(title),
          emoji: emojiUpdate
        ))
      } catch {
        sidebarInteractionLog.error("folder rename failed", error: error)
        ToastCenter.shared.showError("Couldn’t rename the folder. Please try again.")
      }
    }
  }

  private func toggleFolderPin(_ folder: SidebarProjectedFolder) {
    guard let dependencies else { return }
    let pinnedOrder: UpdateDialogFolderTransaction.PinnedOrderUpdate
    if folder.folder.isPinned {
      pinnedOrder = .clear
    } else {
      pinnedOrder = .set(nextSidebarPinnedOrder())
    }

    Task(priority: .userInitiated) {
      do {
        _ = try await dependencies.realtimeV2.send(.updateDialogFolder(
          folderId: folder.id,
          pinnedOrder: pinnedOrder
        ))
      } catch {
        sidebarInteractionLog.error("folder pin update failed", error: error)
        ToastCenter.shared.showError("Couldn’t update the folder pin. Please try again.")
      }
    }
  }

  private func nextSidebarPinnedOrder() -> String {
    let lastPinnedOrder = (
      visiblePinnedItems.compactMap(\.pinnedOrder)
        + viewModel.folders.compactMap(\.pinnedOrder)
    )
    .filter(FractionalIndex.isValid)
    .max()
    return FractionalIndex.after(lastPinnedOrder)
  }

  private func removeFolder(
    _ folder: SidebarProjectedFolder,
    disposition: DeleteDialogFolderTransaction.Disposition
  ) {
    guard pendingRemovedFolderIDs.contains(folder.id) == false else { return }
    // Snapshot the model source, not the expanded row projection, so a
    // collapsed folder still restores every child.
    let childItems = sourceVisibleItems.filter { $0.folderID == folder.id }
    let childIDs = childItems.map(\.id)
    pendingRemovedFolderIDs.insert(folder.id)
    if disposition == .closeDialogs {
      pendingClosedSidebarItemIDs.formUnion(childIDs)
    }

    guard let dependencies else {
      pendingRemovedFolderIDs.remove(folder.id)
      pendingClosedSidebarItemIDs.subtract(childIDs)
      return
    }
    let undoIntent = disposition == .closeDialogs
      ? dependencies.appUndo.beginIntent()
      : nil
    let closedChats = childItems.map { item in
      AppUndoHistory.ClosedChat(
        peer: item.peerId,
        order: item.order,
        folderID: item.folderID,
        pinnedOrder: item.pinnedOrder,
        restoresNestedPin: false
      )
    }
    if disposition == .closeDialogs {
      for child in childItems {
        closeActiveRouteIfNeeded(peer: child.peerId, dependencies: dependencies)
      }
    }
    Task(priority: .userInitiated) {
      do {
        _ = try await dependencies.realtimeV2.send(.deleteDialogFolder(
          folderId: folder.id,
          disposition: disposition
        ))
        if let undoIntent {
          dependencies.appUndo.recordClosedFolder(
            AppUndoHistory.ClosedFolder(
              folderID: folder.id,
              title: folder.folder.title,
              emoji: folder.folder.emoji,
              order: folder.folder.order,
              pinnedOrder: folder.folder.pinnedOrder,
              chats: closedChats
            ),
            intent: undoIntent
          )
        }
      } catch {
        pendingRemovedFolderIDs.remove(folder.id)
        pendingClosedSidebarItemIDs.subtract(childIDs)
        ToastCenter.shared.showError("Couldn’t update the folder. Please try again.")
        sidebarInteractionLog.error("folder removal failed", error: error)
      }
    }
  }

  private func toggleAppKitSection(_ section: SidebarCollectionRow.SectionHeader) {
    if collapsedAppKitSections.remove(section) == nil {
      collapsedAppKitSections.insert(section)
    }
    persistCollapsedAppKitSections()
    sidebarInteractionLog.info(
      "section collapse section=\(section.rawValue) expanded="
        + "\(collapsedAppKitSections.contains(section) == false)"
    )
  }

  private func revealCurrentSidebarSelectionInHierarchy() {
    guard let peer = dependencies?.nav3?.currentReplyThreadPeer ?? selectedPeer,
          let selected = visibleItems.first(where: { $0.peerId == peer })
    else { return }
    let tree = appKitSidebarTree
    let selectedNodeID = SidebarCollectionNodeID.chat(selected.id)
    let projectedLane = tree.snapshot.sectionID(containing: selectedNodeID).flatMap { $0 }
    let section: SidebarCollectionRow.SectionHeader = projectedLane == .pinned
      ? .pinned
      : .content
    if collapsedAppKitSections.remove(section) != nil {
      persistCollapsedAppKitSections()
    }

    var parentID = tree.snapshot.parentID(of: selectedNodeID)
    var changedThreads = false
    var changedFolders = false
    while let currentParentID = parentID {
      switch currentParentID {
      case let .chat(chatID):
        changedThreads = collapsedAppKitThreadParentIDs.remove(chatID) != nil
          || changedThreads
      case let .folder(folderID):
        changedFolders = collapsedAppKitFolderIDs.remove(folderID) != nil
          || changedFolders
      }
      parentID = tree.snapshot.parentID(of: currentParentID)
    }
    if changedThreads {
      persistCollapsedAppKitThreadParentIDs()
    }
    if changedFolders {
      persistCollapsedAppKitFolderIDs()
    }
  }

  private var unreadAboveViewport: SidebarUnreadViewportState? {
    guard hasMeasuredSidebarViewport else { return nil }
    let items = sidebarOrderedItems
    let upperIndex: Int
    if let visibleBounds = visibleSidebarIndexBounds {
      upperIndex = visibleBounds.lowerBound - 1
    } else if let id = lastSidebarItemAboveViewportID,
              let index = items.firstIndex(where: { $0.id == id }) {
      upperIndex = index
    } else {
      return nil
    }
    guard items.indices.contains(upperIndex) else { return nil }
    let unreadItems = items[...upperIndex].filter {
      $0.unread && $0.prominentUnreadDot
    }
    guard let targetID = unreadItems.last?.id else { return nil }
    return SidebarUnreadViewportState(count: unreadItems.count, targetID: targetID)
  }

  private var unreadBelowViewport: SidebarUnreadViewportState? {
    guard hasMeasuredSidebarViewport else { return nil }
    let items = sidebarOrderedItems
    let firstBelowIndex: Int
    if let visibleBounds = visibleSidebarIndexBounds {
      firstBelowIndex = items.index(after: visibleBounds.upperBound)
    } else if let id = firstSidebarItemBelowViewportID,
              let index = items.firstIndex(where: { $0.id == id }) {
      firstBelowIndex = index
    } else {
      return nil
    }
    guard firstBelowIndex < items.endIndex else { return nil }

    let unreadItems = items[firstBelowIndex...].filter {
      $0.unread && $0.prominentUnreadDot
    }
    guard let targetID = unreadItems.first?.id else { return nil }
    return SidebarUnreadViewportState(count: unreadItems.count, targetID: targetID)
  }

  private var visibleSidebarIndexBounds: ClosedRange<Int>? {
    guard hasMeasuredSidebarViewport else { return nil }
    let items = sidebarOrderedItems
    let visibleIndexes = items.indices.filter { visibleSidebarItemIDs.contains(items[$0].id) }
    guard let first = visibleIndexes.min(), let last = visibleIndexes.max() else { return nil }
    return first ... last
  }

  private var visibleTemporaryItem: SidebarViewModel.Item? {
    guard settings.sidebarAsInbox else { return nil }
    guard isArchiveVisible == false else { return nil }
    return viewModel.temporaryItems.last
  }

  private var visibleTemporaryItems: [SidebarViewModel.Item] {
    guard settings.sidebarAsInbox else { return [] }
    guard isArchiveVisible == false else { return [] }
    return viewModel.temporaryItems
  }

  private var visibleItemAnimationKeys: [String] {
    var keys = visibleItems.map { "\($0.id.kind.rawValue)-\($0.id.rawValue)" }
    for item in visibleTemporaryItems {
      keys.append("temporary-\(item.id.kind.rawValue)-\(item.id.rawValue)")
    }
    return keys
  }

  private var sidebarChatRowHeight: CGFloat {
    settings.sidebarItemSize.rowHeight
  }

  private var sidebarTitlesDimmed: Bool {
    !appearsActive
  }

  private var sidebarTitleColor: Color {
    sidebarTitlesDimmed ? Color.secondary : Color.primary
  }

  private var sidebarNavigationSignature: String {
    [
      mainWindowID?.uuidString ?? "",
      String(describing: selectedPeer),
      visibleItemAnimationKeys.joined(separator: ","),
    ].joined(separator: "|")
  }

  private var isTopBarSeparatorHidden: Bool {
    isHomeHovering || isLocationHovering
  }

  private var homeButtonAccessibilityValue: Text {
    guard unreadCounts.prominentUnreadOutsideSelectedSpaceCount > 0 else { return Text("") }
    return Text("Prominent unread chats outside this space")
  }

  private var shouldShowEmptyState: Bool {
    visibleItems.isEmpty && isFetchingVisibleItems == false
  }

  private var isFetchingVisibleItems: Bool {
    guard settings.sidebarAsInbox == false else { return false }
    guard !isArchiveVisible else { return false }

    return dependencies?.session.isFetchingSidebarChats == true
  }

  private var sidebarConnectionState: SidebarConnectionDisplayState? {
    guard !isCollapsed else { return nil }

    if realtimeState.connectionState == .connected {
      return showConnectedState ? .connected : nil
    }

    guard let state = realtimeState.displayedConnectionState else { return nil }
    return SidebarConnectionDisplayState(state)
  }

  private var selectedPeer: Peer? {
    dependencies?.pendingChatPeer ?? nav.currentRoute.selectedPeer
  }

  private var cleanupOwner: UUID {
    cleanupOwnerID
  }

  private var cleanupPreconditionSnapshot: SidebarCleanupPreconditionSnapshot {
    SidebarCleanupPreconditionSnapshot(
      connectionStateKey: cleanupConnectionStateKey,
      hasFetchedServerState: dependencies?.session.hasFetchedSidebarChats == true,
      isFetchingServerState: isFetchingSidebarServerState
    )
  }

  private var sidebarCleanupPreconditions: SidebarCleanup.Preconditions {
    SidebarCleanup.Preconditions(
      hasFetchedServerState: dependencies?.session.hasFetchedSidebarChats == true,
      isFetchingServerState: isFetchingSidebarServerState,
      realtimeConnectionState: realtimeState.connectionState
    )
  }

  private var isFetchingSidebarServerState: Bool {
    dependencies?.session.isFetchingSidebarChats == true
  }

  private var cleanupConnectionStateKey: Int {
    switch realtimeState.connectionState {
    case .connecting:
      return 0
    case .updating:
      return 1
    case .connected:
      return 2
    }
  }

  private func openChat(_ item: SidebarViewModel.Item) {
    SidebarCleanup.shared.markOpened(item.peerId)

    if let dependencies {
      dependencies.requestOpenChat(peer: item.peerId)
      return
    }

    nav.open(.chat(peer: item.peerId))
  }

  private func handleSidebarDrop(
    _ pasteboard: NSPasteboard,
    on item: SidebarViewModel.Item
  ) -> Bool {
    handleSidebarDrop(pasteboard, to: sidebarDropTarget(for: item))
  }

  private func handleSidebarDrop(
    _ pasteboard: NSPasteboard,
    to destination: SidebarDropTarget
  ) -> Bool {
    let capture = InlinePasteboard.captureAttachments(
      from: pasteboard,
      includeText: false
    )

    guard capture.potentialAttachmentCount > 0 else {
      handleSidebarTransferFailure(
        importID: nil,
        message: capture.failures.first?.userFacingMessage
          ?? "No supported attachments were found."
      )
      return false
    }

    let importID = beginSidebarDrop(to: destination)
    sidebarInteractionLog.info(
      "file-drop[\(String(importID.uuidString.prefix(6)))] native captured="
        + "\(capture.potentialAttachmentCount) rejected=\(capture.failures.count)"
    )

    importCapturedSidebarAttachments(
      capture,
      into: destination.peer,
      importID: importID
    )

    return true
  }

  private func makeAppKitExternalDropTarget(
    _ id: ChatListItem.Identifier
  ) -> SidebarCollectionExternalDropTarget? {
    let tree = appKitSidebarTree
    guard let item = tree.itemByID[id] else { return nil }
    let parentPeer = tree.snapshot.parentID(of: .chat(id))
      .flatMap { parentID -> Peer? in
        guard case let .chat(parentChatID) = parentID else { return nil }
        return tree.itemByID[parentChatID]?.peerId
      }
    return SidebarCollectionExternalDropTarget(
      rowID: id,
      peer: item.peerId,
      parentPeer: parentPeer,
      userID: auth.currentUserId,
      generation: appKitExternalDropGeneration
    )
  }

  private func performAppKitExternalDrop(
    _ target: SidebarCollectionExternalDropTarget,
    _ pasteboard: NSPasteboard
  ) -> Bool {
    guard target.userID == auth.currentUserId,
          target.generation == appKitExternalDropGeneration
    else {
      sidebarInteractionLog.warning("file-drop rejected because the sidebar scope changed")
      return false
    }
    return handleSidebarDrop(
      pasteboard,
      to: SidebarDropTarget(peer: target.peer, parentPeer: target.parentPeer)
    )
  }

  private func handleSidebarTransferredDrop(
    _ transfers: [IncomingAttachmentTransfer],
    importID: UUID?,
    on item: SidebarViewModel.Item
  ) {
    // Usually the DropSession begins navigation before Core Transferable
    // delivers its values. If delivery wins that race, preserve the same
    // navigation-first contract here before validating the transferred files.
    let destination = sidebarDropTarget(for: item)
    let resolvedImportID = importID ?? beginSidebarDrop(to: destination)
    let pasteboardResult = InlinePasteboard.findAttachmentsResult(from: transfers)
    let attachments = pasteboardResult.attachments
    sidebarInteractionLog.info(
      "file-drop[\(String(resolvedImportID.uuidString.prefix(6)))] transferable delivered="
        + "\(transfers.count) decoded=\(attachments.count) rejected=\(pasteboardResult.failures.count)"
    )

    guard attachments.isEmpty == false else {
      cleanupTransferredAttachments(transfers)
      handleSidebarTransferFailure(
        importID: resolvedImportID,
        message: pasteboardResult.failures.first?.userFacingMessage
          ?? "No supported attachments were found."
      )
      return
    }

    importSidebarAttachments(
      pasteboardResult,
      into: destination.peer,
      importID: resolvedImportID,
      transferredAttachments: transfers
    )
  }

  private func sidebarDropTarget(
    for item: SidebarViewModel.Item
  ) -> SidebarDropTarget {
    let parentPeer = item.parentChatId.flatMap { parentChatID in
      (visibleItems + visibleTemporaryItems)
        .first(where: { $0.chatId == parentChatID })?
        .peerId
    }
    return SidebarDropTarget(peer: item.peerId, parentPeer: parentPeer)
  }

  private func beginSidebarDrop(to destination: SidebarDropTarget) -> UUID {
    let importID = UUID()
    activeDropImportJobs[importID] = SidebarDropImportJob(userID: auth.currentUserId)
    sidebarInteractionLog.info(
      "file-drop[\(String(importID.uuidString.prefix(6)))] navigation began "
        + "target=\(destination.parentPeer == nil ? "root" : "reply")"
    )
    activateDropDestinationWindow()

    // Navigation and attachment materialization are independent. Opening now
    // lets the composer either load a fast result from Drafts2 or observe a
    // slower result while Drafts2 prepares it in the background.
    openSidebarDropTarget(destination)
    return importID
  }

  private func openSidebarDropTarget(_ destination: SidebarDropTarget) {
    guard let dependencies else {
      nav.open(.chat(peer: destination.peer))
      return
    }

    if case .replySidePane = SidebarDropNavigationPolicy.presentation(
      presentationParentExists: destination.parentPeer != nil,
      prefersReplySidePane: AppSettings.shared.openReplyThreadsInSidePane
    ), let parentPeer = destination.parentPeer {
      dependencies.openReplyThreadInPane(
        parentPeer: parentPeer,
        threadPeer: destination.peer
      )
      return
    }

    // Drop acceptance commits navigation immediately; ordinary chat clicks
    // retain their preload path, but attachment materialization must not delay
    // or later replace the captured destination.
    dependencies.openChatRoute(peer: destination.peer)
  }

  private func activateDropDestinationWindow() {
    guard let appBridge = dependencies?.appBridge else {
      NSApp.activate(ignoringOtherApps: true)
      return
    }

    appBridge.currentWindow()?.makeKeyAndOrderFront(nil)
    appBridge.activate(ignoringOtherApps: true)
  }

  private func importSidebarAttachments(
    _ pasteboardResult: PasteboardAttachmentResult,
    into peer: Peer,
    importID: UUID,
    transferredAttachments: [IncomingAttachmentTransfer] = []
  ) {
    guard let job = activeDropImportJobs[importID] else { return }
    let attachments = pasteboardResult.attachments
    job.task = Task { @MainActor in
      guard isSidebarDropImportCurrent(importID) else {
        cleanupTransferredAttachments(transferredAttachments)
        return
      }
      let summary = await DraftAttachmentImporter.import(
        attachments,
        into: peer
      )
      cleanupTransferredAttachments(transferredAttachments)
      finishSidebarImport(
        importID: importID,
        importedCount: summary.importedCount,
        failedCount: pasteboardResult.failures.count + summary.failedCount
      )
    }
  }

  private func importCapturedSidebarAttachments(
    _ capture: PasteboardAttachmentCapture,
    into peer: Peer,
    importID: UUID
  ) {
    guard let job = activeDropImportJobs[importID] else { return }
    job.task = Task { @MainActor in
      let prepared = await capture.materialize()
      defer { prepared.cleanup() }
      guard isSidebarDropImportCurrent(importID) else { return }
      guard prepared.attachments.isEmpty == false else {
        handleSidebarTransferFailure(
          importID: importID,
          message: prepared.failures.first?.userFacingMessage
            ?? "No supported attachments were found."
        )
        return
      }

      let summary = await DraftAttachmentImporter.import(
        prepared.attachments,
        into: peer
      )
      finishSidebarImport(
        importID: importID,
        importedCount: summary.importedCount,
        failedCount: prepared.failures.count + summary.failedCount
      )
    }
  }

  private func finishSidebarImport(
    importID: UUID,
    importedCount: Int,
    failedCount: Int
  ) {
    sidebarInteractionLog.info(
      "file-drop[\(String(importID.uuidString.prefix(6)))] import finished "
        + "imported=\(importedCount) failed=\(failedCount)"
    )
    if failedCount > 0 {
      Log.shared.error("Sidebar drop failed to prepare \(failedCount) item(s)")
    }

    guard activeDropImportJobs.removeValue(forKey: importID) != nil else { return }

    if failedCount > 0 {
      ToastCenter.shared.showError(
        failedCount == 1
          ? "One dropped item couldn't be added."
          : "Some dropped items couldn't be added."
      )
    } else if importedCount == 0 {
      ToastCenter.shared.showError("No supported attachments were found.")
    }
  }

  private func handleSidebarTransferFailure(
    importID: UUID?,
    message: String = "Couldn't prepare that item."
  ) {
    if let importID {
      guard activeDropImportJobs.removeValue(forKey: importID) != nil else { return }
    }
    ToastCenter.shared.showError(message)
  }

  private func isSidebarDropImportCurrent(_ importID: UUID) -> Bool {
    guard let job = activeDropImportJobs[importID] else { return false }
    return job.userID == auth.currentUserId
      && !Auth.shared.handle.hasPendingAccountTransition()
      && !Task.isCancelled
  }

  private func cancelSidebarDropImports() {
    let jobs = activeDropImportJobs.values
    activeDropImportJobs.removeAll()
    jobs.forEach { $0.task?.cancel() }
    Drafts2.shared.cancelAllPendingAttachments()
  }

  private func cleanupTransferredAttachments(
    _ transfers: [IncomingAttachmentTransfer]
  ) {
    guard transfers.isEmpty == false else { return }
    _ = Task.detached(priority: .utility) {
      for transfer in transfers {
        transfer.cleanup()
      }
    }
  }

  private func closeChat(_ item: SidebarViewModel.Item) {
    guard settings.sidebarAsInbox else { return }

    if isTemporaryItem(item) {
      viewModel.setTemporaryPeer(nil)
      return
    }

    guard let dependencies else { return }
    let itemsToClose = appKitAttachedGroupItems(startingAt: item)
    closeSidebarItems(
      itemsToClose,
      dependencies: dependencies,
      undoIntent: dependencies.appUndo.beginIntent(),
      showsCompletionToast: false
    )
  }

  private func closeSidebarItems(
    _ itemsToClose: [SidebarViewModel.Item],
    dependencies: AppDependencies,
    undoIntent: AppUndoHistory.Intent?,
    showsCompletionToast: Bool
  ) {
    let itemIDsToClose = Set(itemsToClose.map(\.id))
    guard itemIDsToClose.isEmpty == false else { return }
    guard pendingClosedSidebarItemIDs.isDisjoint(with: itemIDsToClose) else {
      sidebarInteractionLog.debug("ignored repeated close while the existing request is pending")
      return
    }

    // The dialog model remains authoritative, but waiting for its realtime
    // observation kept a successfully clicked row fully interactive for
    // several seconds. Project the pending mutation immediately so the first
    // click owns one close animation and cannot enqueue duplicate requests.
    pendingClosedSidebarItemIDs.formUnion(itemIDsToClose)
    for itemToClose in itemsToClose {
      closeActiveRouteIfNeeded(peer: itemToClose.peerId, dependencies: dependencies)
    }

    Task(priority: .userInitiated) {
      var failedItemIDs = Set<ChatListItem.Identifier>()
      var closedChats: [AppUndoHistory.ClosedChat] = []
      for itemToClose in itemsToClose {
        do {
          if itemToClose.pinned, itemToClose.parentChatId != nil {
            _ = try await dependencies.realtimeV2.send(.updateDialogOrder(
              peerId: itemToClose.peerId,
              pinned: false
            ))
          }
          _ = try await dependencies.realtimeV2.send(
            .updateDialogOpen(peerId: itemToClose.peerId, open: false)
          )
          closedChats.append(AppUndoHistory.ClosedChat(
            peer: itemToClose.peerId,
            order: itemToClose.order,
            folderID: itemToClose.folderID,
            pinnedOrder: itemToClose.pinnedOrder,
            restoresNestedPin: itemToClose.pinned && itemToClose.parentChatId != nil
          ))
        } catch {
          failedItemIDs.insert(itemToClose.id)
          Log.shared.error("Failed to close chat in sidebar", error: error)
        }
      }
      if let undoIntent {
        dependencies.appUndo.recordClosedChats(closedChats, intent: undoIntent)
      }
      if showsCompletionToast {
        let closedCount = closedChats.count
        let failedCount = failedItemIDs.count
        let message = if failedCount == 0 {
          "Closed \(closedCount) \(closedCount == 1 ? "chat" : "chats")"
        } else {
          "Closed \(closedCount); \(failedCount) couldn’t be closed"
        }
        if failedCount == 0 {
          ToastCenter.shared.showSuccess(message)
        } else {
          ToastCenter.shared.showError(message)
        }
      }
      guard failedItemIDs.isEmpty == false else { return }
      await MainActor.run {
        pendingClosedSidebarItemIDs.subtract(failedItemIDs)
        if showsCompletionToast == false {
          ToastCenter.shared.showError(
            failedItemIDs.count == 1
              ? "Couldn’t close that chat"
              : "Some chats couldn’t be closed"
          )
        }
      }
    }
  }

  private func prunePendingSidebarCloses() {
    guard pendingClosedSidebarItemIDs.isEmpty == false else { return }
    let sourceIDs = Set(sourceVisibleItems.map(\.id))
    pendingClosedSidebarItemIDs.formIntersection(sourceIDs)
  }

  private func cleanUpOpenChats() {
    guard let dependencies else { return }
    SidebarCleanup.shared.cleanNow(realtimeV2: dependencies.realtimeV2) { result in
      switch result {
      case let .cleaned(chats, folders):
        let message = switch (chats, folders) {
        case (0, 0):
          "No chats or folders to clean up"
        case (let chats, 0):
          "Cleaned up \(chats) \(chats == 1 ? "chat" : "chats")"
        case (0, let folders):
          "Deleted \(folders) empty \(folders == 1 ? "folder" : "folders")"
        case let (chats, folders):
          "Cleaned up \(chats) \(chats == 1 ? "chat" : "chats") and deleted \(folders) empty \(folders == 1 ? "folder" : "folders")"
        }
        ToastCenter.shared.showSuccess(message)
      case .unavailable:
        ToastCenter.shared.showInfo("Cleanup isn’t available right now")
      case .failed:
        ToastCenter.shared.showError("Couldn’t clean up chats and folders")
      }
    }
  }

  private func closeAllOpenChats() {
    guard settings.sidebarAsInbox, let dependencies else { return }
    let tree = appKitSidebarTree
    var seenItemIDs = Set<ChatListItem.Identifier>()
    let openItems = visibleNormalSourceItems.filter { item in
      guard seenItemIDs.insert(item.id).inserted else { return false }
      return tree.snapshot.sectionID(containing: .chat(item.id)).flatMap { $0 } == .normal
    }

    // Preserve the existing temporary-row behavior. These rows are a local
    // navigation projection rather than dialog-open state, so Close All
    // operates only on persisted dialogs.
    let persistedOpenItems = openItems.filter { isTemporaryItem($0) == false }
    if persistedOpenItems.count != openItems.count {
      viewModel.setTemporaryPeer(nil)
    }

    closeSidebarItems(
      persistedOpenItems,
      dependencies: dependencies,
      undoIntent: nil,
      showsCompletionToast: true
    )
  }

  private func appKitAttachedGroupItems(
    startingAt item: SidebarViewModel.Item
  ) -> [SidebarViewModel.Item] {
    // Project without collapse filtering so closing a collapsed head also closes
    // every reply still attached to it. Detached replies remain independent roots.
    let projectedItems = SidebarCollectionProjection.projectSidebar(
      pinnedItems: visiblePinnedItems,
      normalItems: visibleNormalSourceItems,
      collapsedParentIDs: [],
      detachedReplyIDs: detachedAppKitReplyIDs,
      nestingPolicy: .replyThreads
    ).compactMap(\.projectedItem)
    guard let startIndex = projectedItems.firstIndex(where: { $0.id == item.id }) else {
      return [item]
    }

    let start = projectedItems[startIndex]
    guard start.isExpandable else { return [item] }

    var result = [start.item]
    for candidate in projectedItems.dropFirst(startIndex + 1) {
      guard candidate.depth > start.depth else { break }
      result.append(candidate.item)
    }
    return result
  }

  private func closeActiveRouteIfNeeded(peer: Peer, dependencies: AppDependencies) {
    guard isActiveRoute(peer, dependencies: dependencies) else { return }
    _ = dependencies.removeChatFromNavigation(peer: peer)
  }

  private func isActiveRoute(_ peer: Peer, dependencies: AppDependencies) -> Bool {
    if nav.currentRoute.selectedPeer == peer {
      return true
    }

    if dependencies.nav3?.currentRoute.selectedPeer == peer {
      return true
    }

    if dependencies.nav2?.currentRoute.selectedPeer == peer {
      return true
    }

    return false
  }

  private func isTemporaryItem(_ item: SidebarViewModel.Item) -> Bool {
    visibleTemporaryItems.contains { $0.peerId == item.peerId }
  }

  private func persistTemporaryChat(_ item: SidebarViewModel.Item) {
    guard settings.sidebarAsInbox else { return }
    guard isTemporaryItem(item) else { return }
    SidebarCleanup.shared.markOpened(item.peerId)
    SidebarState.shared.keepInSidebar(item.peerId)
  }

  private func updateSidebarDrag(
    item: SidebarViewModel.Item,
    lane: SidebarOrderLane?,
    items: [SidebarViewModel.Item],
    value: DragGesture.Value,
    rowSize: CGSize
  ) {
    guard settings.sidebarAsInbox else { return }
    guard let lane else { return }

    sidebarDrag.dragChanged(
      item: item,
      lane: lane,
      sourceItems: items,
      pinnedItems: visiblePinnedItems,
      normalItems: visibleNormalSourceItems,
      value: value,
      rowSize: rowSize,
      rowHeight: sidebarChatRowHeight,
      colorScheme: colorScheme,
      commit: applySidebarOrder
    )
  }

  private func endSidebarDrag() {
    guard let commit = sidebarDrag.dragEnded() else { return }

    applySidebarOrder(commit)
  }

  private func applySidebarOrder(_ commit: SidebarDragCommit) {
    applySidebarOrder(
      commit.targetItems,
      movedItem: commit.movedItem,
      newIndex: commit.newIndex,
      sourceLane: commit.sourceLane,
      targetLane: commit.targetLane
    )
  }

  private func applyAppKitSidebarMove(
    _ intent: SidebarCollectionMoveIntent,
    completion: @escaping @MainActor @Sendable (Bool) -> Void
  ) {
    switch intent {
    case let .chat(move):
      applyAppKitChatMove(move, completion: completion)
    case let .folder(move):
      applyAppKitFolderMove(move, completion: completion)
    }
  }

  private func applyAppKitFolderMove(
    _ move: SidebarCollectionFolderMove,
    completion: @escaping @MainActor @Sendable (Bool) -> Void
  ) {
    if effectiveSidebarSort == .recentActivity,
       !SidebarCollectionReorderPolicy.pinningOnly.allowsFolderMove(
         changesSection: move.sourceLane != move.targetLane,
         reordersStableNormalLane: move.sourceLane == .normal
           && move.targetLane == .normal
       ) {
      sidebarInteractionLog.error("rejected unstable folder reorder in recent-activity mode")
      completion(false)
      return
    }
    guard let dependencies,
          let order = safeSidebarInsertionOrder(
            hasPrevious: move.hasPreviousOrder,
            previousOrder: move.previousOrder,
            hasNext: move.hasNextOrder,
            nextOrder: move.nextOrder
          )
    else {
      sidebarInteractionLog.error("folder reorder rejected because destination orders are invalid")
      completion(false)
      return
    }
    Task(priority: .userInitiated) {
      do {
        switch move.targetLane {
        case .pinned:
          _ = try await dependencies.realtimeV2.send(.updateDialogFolder(
            folderId: move.folder.id,
            pinnedOrder: .set(order)
          ))
        case .normal:
          _ = try await dependencies.realtimeV2.send(.updateDialogFolder(
            folderId: move.folder.id,
            pinnedOrder: move.sourceLane == .pinned ? .clear : .unchanged,
            order: order
          ))
        }
        completion(true)
      } catch {
        sidebarInteractionLog.error("folder reorder persistence failed", error: error)
        completion(false)
      }
    }
  }

  private func applyAppKitChatMove(
    _ move: SidebarCollectionMove,
    completion: @escaping @MainActor @Sendable (Bool) -> Void
  ) {
    if effectiveSidebarSort == .recentActivity {
      let entersPinnedContainer = isMoveIntoPinnedFolder(move)
      guard SidebarCollectionReorderPolicy.pinningOnly.allowsMove(
        sourceIsRoot: move.sourceIsRoot,
        changesSection: move.sourceLane != move.targetLane,
        changesParent: move.hierarchyChange != nil || move.dialogDestination != nil,
        entersPinnedContainer: entersPinnedContainer
      )
      else {
        sidebarInteractionLog.error("rejected manual reorder in recent-activity mode")
        completion(false)
        return
      }
      if entersPinnedContainer == false {
        applyRecentActivityPinMove(move, completion: completion)
        return
      }
    }

    let detachedReplyIDsBeforeMove = detachedAppKitReplyIDs
    if let hierarchyChange = move.hierarchyChange {
      switch hierarchyChange {
      case let .detach(id):
        detachedAppKitReplyIDs.insert(id)
      case let .attach(id, parentID):
        guard let source = appKitProjectedVisibleItems.first(where: { $0.id == id }),
              source.semanticParentID == parentID
        else {
          sidebarInteractionLog.error("rejected invalid reply reattachment")
          completion(false)
          return
        }
        detachedAppKitReplyIDs.remove(id)
      }
      persistDetachedAppKitReplyIDs()
      sidebarInteractionLog.info(
        "presentation hierarchy changed=\(String(describing: hierarchyChange)) "
          + "detachedReplies=\(detachedAppKitReplyIDs.count)"
      )
    }

    guard let targetOrder = safeSidebarInsertionOrder(
      hasPrevious: move.hasPreviousOrder,
      previousOrder: move.previousOrder,
      hasNext: move.hasNextOrder,
      nextOrder: move.nextOrder
    ) else {
      if move.hierarchyChange != nil {
        detachedAppKitReplyIDs = detachedReplyIDsBeforeMove
        persistDetachedAppKitReplyIDs()
      }
      sidebarInteractionLog.error("reorder rejected because destination orders are incomplete")
      completion(false)
      return
    }

    persistSidebarOrder(
      movedItem: move.movedItem,
      targetOrder: targetOrder,
      sourceLane: move.sourceLane,
      targetLane: move.targetLane,
      destination: move.dialogDestination,
      targetIndex: move.newIndex,
      onFailure: move.hierarchyChange == nil ? nil : {
        detachedAppKitReplyIDs = detachedReplyIDsBeforeMove
        persistDetachedAppKitReplyIDs()
        sidebarInteractionLog.warning("rolled back presentation hierarchy after reorder failure")
      },
      completion: completion
    )
  }

  private func isMoveIntoPinnedFolder(_ move: SidebarCollectionMove) -> Bool {
    guard case let .folder(folderID)? = move.dialogDestination else { return false }
    return viewModel.folders.first(where: { $0.id == folderID })?.isPinned == true
  }

  private func applyRecentActivityPinMove(
    _ move: SidebarCollectionMove,
    completion: @escaping @MainActor @Sendable (Bool) -> Void
  ) {
    guard let dependencies else {
      completion(false)
      return
    }
    let pinned = move.targetLane == .pinned
    sidebarInteractionLog.info(
      "recent-activity pin commit pinned=\(pinned) updates=1"
    )
    Task(priority: .userInitiated) {
      do {
        _ = try await dependencies.realtimeV2.send(.updateDialogOrder(
          peerId: move.movedItem.peerId,
          pinned: pinned
        ))
        completion(true)
      } catch {
        sidebarInteractionLog.error("recent-activity pin persistence failed", error: error)
        completion(false)
      }
    }
  }

  private func persistDetachedAppKitReplyIDs() {
    SidebarPresentationStateStore().setDetachedReplyIDs(
      detachedAppKitReplyIDs,
      userID: appKitPresentationStateUserID
    )
  }

  private func persistCollapsedAppKitThreadParentIDs() {
    SidebarPresentationStateStore().setCollapsedParentIDs(
      collapsedAppKitThreadParentIDs,
      userID: appKitPresentationStateUserID
    )
  }

  private func persistCollapsedAppKitFolderIDs() {
    SidebarPresentationStateStore().setCollapsedFolderIDs(
      collapsedAppKitFolderIDs,
      userID: appKitPresentationStateUserID
    )
  }

  private func persistCollapsedAppKitSections() {
    SidebarPresentationStateStore().setCollapsedSections(
      collapsedAppKitSections,
      userID: appKitPresentationStateUserID
    )
  }

  private func syncAppKitPresentationState(userID: Int64?) {
    guard appKitPresentationStateUserID != userID else { return }
    appKitPresentationStateUserID = userID
    let store = SidebarPresentationStateStore()
    detachedAppKitReplyIDs = store.detachedReplyIDs(userID: userID)
    collapsedAppKitThreadParentIDs = store.collapsedParentIDs(userID: userID)
    collapsedAppKitFolderIDs = store.collapsedFolderIDs(userID: userID)
    collapsedAppKitSections = store.collapsedSections(userID: userID)
  }

  private func applySidebarOrder(
    _ reorderedItems: [SidebarViewModel.Item],
    movedItem: SidebarViewModel.Item,
    newIndex: Int,
    sourceLane: SidebarOrderLane,
    targetLane: SidebarOrderLane,
    onFailure: (@MainActor @Sendable () -> Void)? = nil,
    completion: (@MainActor @Sendable (Bool) -> Void)? = nil
  ) {
    let movedItemIsTemporary = isTemporaryItem(movedItem)
    let orderItems = movedItemIsTemporary ? reorderedItems : reorderedItems.filter { isTemporaryItem($0) == false }
    guard let orderIndex = orderItems.firstIndex(where: { $0.id == movedItem.id }) else {
      onFailure?()
      completion?(false)
      return
    }

    let previousIndex = orderIndex > orderItems.startIndex ? orderItems.index(before: orderIndex) : nil
    let nextIndex = orderItems.index(after: orderIndex)
    let previousItem = previousIndex.map { orderItems[$0] }
    let nextItem = nextIndex < orderItems.endIndex ? orderItems[nextIndex] : nil
    guard let targetOrder = sidebarOrder(
      previousItem: previousItem,
      nextItem: nextItem,
      lane: targetLane
    ) else {
      sidebarInteractionLog.error(
        "reorder rejected because neighboring dialog orders are incomplete or invalid"
      )
      onFailure?()
      completion?(false)
      return
    }

    persistSidebarOrder(
      movedItem: movedItem,
      targetOrder: targetOrder,
      sourceLane: sourceLane,
      targetLane: targetLane,
      destination: nil,
      targetIndex: newIndex,
      onFailure: onFailure,
      completion: completion
    )
  }

  private func persistSidebarOrder(
    movedItem: SidebarViewModel.Item,
    targetOrder: String,
    sourceLane: SidebarOrderLane,
    targetLane: SidebarOrderLane,
    destination: DialogOrderDestination?,
    targetIndex: Int,
    onFailure: (@MainActor @Sendable () -> Void)? = nil,
    completion: (@MainActor @Sendable (Bool) -> Void)? = nil
  ) {
    guard let dependencies else {
      onFailure?()
      completion?(false)
      return
    }
    let movedItemIsTemporary = isTemporaryItem(movedItem)

    let isCrossLaneMove = sourceLane != targetLane
    guard targetOrder != targetLane.order(for: movedItem)
      || isCrossLaneMove
      || movedItemIsTemporary
      || destination != nil
    else {
      completion?(true)
      return
    }
    sidebarInteractionLog.info(
      "reorder commit targetIndex=\(targetIndex) sourceLane=\(sourceLane.rawValue) "
        + "targetLane=\(targetLane.rawValue) updates=1 "
        + "temporary=\(movedItemIsTemporary)"
    )
    Task(priority: .userInitiated) {
      do {
        if isCrossLaneMove || movedItemIsTemporary {
          switch targetLane {
          case .normal:
            _ = try await dependencies.realtimeV2.send(.updateDialogOrder(
              peerId: movedItem.peerId,
              order: targetOrder,
              pinned: false,
              destination: destination
            ))
          case .pinned:
            _ = try await dependencies.realtimeV2.send(.updateDialogOrder(
              peerId: movedItem.peerId,
              pinnedOrder: targetOrder,
              pinned: true,
              destination: destination
            ))
          }
        } else {
          switch targetLane {
          case .normal:
            _ = try await dependencies.realtimeV2.send(.updateDialogOrder(
              peerId: movedItem.peerId,
              order: targetOrder,
              destination: destination
            ))
          case .pinned:
            _ = try await dependencies.realtimeV2.send(.updateDialogOrder(
              peerId: movedItem.peerId,
              pinnedOrder: targetOrder,
              destination: destination
            ))
          }
        }
        sidebarInteractionLog.info(
          "reorder persisted targetIndex=\(targetIndex) targetLane=\(targetLane.rawValue) "
            + "updates=1"
        )
        completion?(true)
      } catch {
        sidebarInteractionLog.error("reorder persistence failed", error: error)
        Log.shared.error("Failed to reorder sidebar chat", error: error)
        onFailure?()
        completion?(false)
      }
    }
  }

  /// Produces the one fractional-order mutation required for a reorder.
  ///
  /// A corrupt or partially ordered lane is rejected instead of attempting a
  /// client-side multi-RPC renumber. That keeps every accepted drag atomic at
  /// the persistence boundary; lane repair belongs in a dedicated server
  /// transaction, not in an interactive drop.
  private func sidebarOrder(
    previousItem: SidebarViewModel.Item?,
    nextItem: SidebarViewModel.Item?,
    lane: SidebarOrderLane
  ) -> String? {
    let previousOrder = lane.order(for: previousItem)
    let nextOrder = lane.order(for: nextItem)
    return safeSidebarInsertionOrder(
      hasPrevious: previousItem != nil,
      previousOrder: previousOrder,
      hasNext: nextItem != nil,
      nextOrder: nextOrder
    )
  }

  private func safeSidebarInsertionOrder(
    hasPrevious: Bool,
    previousOrder: String?,
    hasNext: Bool,
    nextOrder: String?
  ) -> String? {
    guard previousOrder.map(FractionalIndex.isValid) ?? true,
          nextOrder.map(FractionalIndex.isValid) ?? true
    else { return nil }
    return SidebarCollectionOrderPlanner.insertionOrder(
      hasPrevious: hasPrevious,
      previousOrder: previousOrder,
      hasNext: hasNext,
      nextOrder: nextOrder,
      between: FractionalIndex.between
    )
  }

  private func openAllChats() {
    guard settings.sidebarAsInbox else { return }
    nav.open(.allChats)
  }

  private func selectHome() {
    nav.selectHome()
  }

  private func selectSpace(_ spaceId: Int64) {
    nav.selectSpace(spaceId)
  }

  private func openDocs() {
    openExternalURL("https://inline.chat/docs")
  }

  private func openTownHall() {
    guard let dependencies else {
      ToastCenter.shared.showError("Couldn’t join Town Hall. Please try again.")
      return
    }

    Task(priority: .userInitiated) {
      do {
        let result = try await dependencies.realtimeV2.send(.joinPublicSpace(handle: "townhall"))
        guard case .joinPublicSpace = result else {
          throw TransactionExecutionError.invalid
        }
        selectHome()
      } catch {
        ToastCenter.shared.showError("Couldn’t join Town Hall. Please try again.")
      }
    }
  }

  private func dmFounder() {
#if DEBUG
    let moUserID: Int64 = 1_300
#else
    let moUserID: Int64 = 1_600
#endif
    let peer = Peer.user(id: moUserID)
    guard let dependencies else {
      nav.open(.chat(peer: peer))
      return
    }
    Task(priority: .userInitiated) {
      await dependencies.realtimeV2.sendQueued(.updateDialogOpen(peerId: peer, open: true))
    }
    dependencies.requestOpenChat(peer: peer)
  }

  private func openWhatsNew() {
    openExternalURL("https://inline.chat/docs/changelog")
  }

  private func openStatus() {
    openExternalURL("https://status.inline.chat/")
  }

  private func openExternalURL(_ string: String) {
    guard let url = URL(string: string) else { return }
    NSWorkspace.shared.open(url)
  }

  private func createNewThread() {
    guard let dependencies else {
      nav.open(.newChat(spaceId: activeSpaceId))
      return
    }

    NewThreadAction.start(dependencies: dependencies, nav: nav)
  }

  private func createNewThread(inFolder folderID: Int64) {
    guard let dependencies else {
      nav.open(.newChat(spaceId: activeSpaceId))
      return
    }

    NewThreadAction.start(
      dependencies: dependencies,
      spaceId: activeSpaceId,
      destinationFolderId: folderID
    )
  }

  private func performSpaceAction(_ pending: SidebarSpacePendingAction) {
    pendingSpaceAction = nil
    let shouldNavigateOut = isActiveSpace(pending.space.id)
    ToastCenter.shared.showLoading(pending.action.loadingTitle)

    Task(priority: .userInitiated) {
      do {
        let data = dependencies?.data ?? DataManager.shared

        switch pending.action {
        case .delete:
          try await data.deleteSpace(spaceId: pending.space.id)
        case .leave:
          try await data.leaveSpace(spaceId: pending.space.id)
        }

        await MainActor.run {
          ToastCenter.shared.dismiss()
          if shouldNavigateOut {
            navigateOutOfSpace()
          }
          ToastCenter.shared.showSuccess(pending.action.successTitle)
        }
      } catch {
        Log.shared.error(pending.action.failureTitle, error: error)

        await MainActor.run {
          ToastCenter.shared.dismiss()
          ToastCenter.shared.showError(pending.action.failureTitle)
        }
      }
    }
  }

  private func isActiveSpace(_ spaceId: Int64) -> Bool {
    nav.selectedSpaceId == spaceId || dependencies?.activeSpaceId == spaceId
  }

  private func navigateOutOfSpace() {
    nav.selectHome()
    nav.open(.empty)
    dependencies?.nav2?.setActiveTab(index: 0)
    dependencies?.nav2?.navigate(to: .empty)
    dependencies?.nav3?.selectHome()
    dependencies?.nav3?.open(.empty)
  }

  private func navigateChat(offset: Int) {
    let items = appKitProjectedVisibleItems.map(\.item)
    guard items.isEmpty == false else { return }

    let currentIndex = selectedPeer.flatMap { peer in
      items.firstIndex { $0.peerId == peer }
    } ?? -1

    let targetIndex = currentIndex + offset
    guard items.indices.contains(targetIndex) else { return }

    openChat(items[targetIndex])
  }

  private func scrollToUnread(
    _ unread: SidebarUnreadViewportState,
    using scrollProxy: ScrollViewProxy? = nil
  ) {
    _ = scrollProxy
    appKitScrollRequestToken &+= 1
    appKitScrollRequest = SidebarCollectionScrollRequest(
      itemID: unread.targetID,
      token: appKitScrollRequestToken
    )
  }

  private func setSidebarItemVisibility(_ id: ChatListItem.Identifier, isVisible: Bool) {
    hasMeasuredSidebarViewport = true
    lastSidebarItemAboveViewportID = nil
    firstSidebarItemBelowViewportID = nil
    if isVisible {
      visibleSidebarItemIDs.insert(id)
    } else {
      visibleSidebarItemIDs.remove(id)
    }
  }

  private func pruneVisibleSidebarItems() {
    let itemIDs = Set(sidebarOrderedItems.map(\.id))
    visibleSidebarItemIDs = visibleSidebarItemIDs.intersection(itemIDs)
    if let id = lastSidebarItemAboveViewportID, itemIDs.contains(id) == false {
      lastSidebarItemAboveViewportID = nil
    }
    if let id = firstSidebarItemBelowViewportID, itemIDs.contains(id) == false {
      firstSidebarItemBelowViewportID = nil
    }
  }

  private func resetSidebarVisibility() {
    visibleSidebarItemIDs.removeAll()
    hasMeasuredSidebarViewport = false
    lastSidebarItemAboveViewportID = nil
    firstSidebarItemBelowViewportID = nil
  }

  private func registerSidebarNavigation() {
    guard let mainWindowID else { return }

    MainWindowOpenCoordinator.shared.registerSidebarNavigation(id: mainWindowID) { offset in
      navigateChat(offset: offset)
    }
  }

  private func unregisterSidebarNavigation() {
    guard let mainWindowID else { return }
    MainWindowOpenCoordinator.shared.unregisterSidebarNavigation(id: mainWindowID)
  }

  private func refreshSidebarCleanup() {
    guard let dependencies else { return }
    SidebarCleanup.shared.activate(
      owner: cleanupOwner,
      realtimeV2: dependencies.realtimeV2,
      preconditions: sidebarCleanupPreconditions
    )
  }

  private func deactivateSidebarCleanup() {
    SidebarCleanup.shared.deactivate(owner: cleanupOwner)
  }

  private func syncSource(spaceId: Int64?) {
    // Establish ordering before a new observation can synchronously publish so
    // a mode change never presents one frame in the previous sort policy.
    viewModel.setSortMode(effectiveSidebarSort)
    let mode = settings.sidebarAsInbox ? SidebarViewModel.ContentMode.inbox : .chatList

    if let spaceId {
      viewModel.selectSpace(spaceId, mode: mode)
    } else {
      viewModel.selectHome(mode: mode)
    }
  }

  private func syncUnreadCountsScope(spaceId: Int64?) {
    syncUnreadCountsScope(
      spaceId: spaceId,
      includeSpaceChatsInHome: settings.includeSpaceChatsInHomeSidebar
    )
  }

  private func syncUnreadCountsScope(spaceId: Int64?, includeSpaceChatsInHome: Bool) {
    unreadCounts.setSidebarScope(
      spaceId: spaceId,
      includeSpaceChatsInHome: includeSpaceChatsInHome
    )
  }

  private func validateSelectedSpace() {
    guard let spaceId = nav.selectedSpaceId else { return }
    guard viewModel.hasSpace(id: spaceId) == false else { return }
    os_log(
      .default,
      log: Self.firstFrameDiagnostics,
      "component=swiftui event=restored-space-invalid spaces=%{public}d action=select-home",
      viewModel.spaces.count
    )
    nav.selectHome()
  }

  private func handleRealtimeConnectionStateChange(_ state: RealtimeConnectionState) {
    switch state {
    case .connected:
      showConnectedTemporarily()
    case .connecting, .updating:
      hideConnectedTask?.cancel()
      hideConnectedTask = nil
      showConnectedState = false
    }
  }

  private func showConnectedTemporarily() {
    showConnectedState = true
    hideConnectedTask?.cancel()
    hideConnectedTask = Task { @MainActor in
      do {
        try await Task.sleep(for: .seconds(1))
      } catch {
        return
      }

      guard realtimeState.connectionState == .connected else { return }
      showConnectedState = false
      hideConnectedTask = nil
    }
  }

}

#Preview {
  SidebarView()
    .environment(SidebarViewModel(db: .populated()))
    .environment(UnreadCountsModel(database: .populated()))
    .environmentObject(RealtimeState())
#if SPARKLE
    .environment(UpdateController())
#endif
    .frame(width: 280, height: 480)
}

extension EdgeInsets {
  static var zero = EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
}

private struct SidebarTopBarHoverBackground: View {
  let isHovering: Bool

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    RoundedRectangle(cornerRadius: Theme.sidebarItemRadius, style: .continuous)
      .fill(backgroundColor)
  }

  private var backgroundColor: Color {
    guard isHovering else { return .clear }
    return colorScheme == .dark ? .white.opacity(0.06) : .black.opacity(0.05)
  }
}

private enum SidebarTopBarMetrics {
  static let buttonHeight: CGFloat = 30
  static let leadingPadding = Theme.sidebarItemInnerSpacing + 3
}

private struct SidebarUnreadViewportState: Equatable {
  let count: Int
  let targetID: ChatListItem.Identifier
}

private struct SidebarCleanupPreconditionSnapshot: Equatable {
  let connectionStateKey: Int
  let hasFetchedServerState: Bool
  let isFetchingServerState: Bool
}

private struct SidebarInboxActionRow: View {
  let title: String
  let systemImage: String
  let selected: Bool
  let titleDimmed: Bool
  let size: SidebarItemSize
  let prominentUnreadCount: Int
  let nonProminentUnreadCount: Int
  var usesFullWidthCollectionLayout = false
  let action: () -> Void

  @Environment(\.colorScheme) private var colorScheme
  @State private var isHovered = false

  private static let titleFont: Font = .system(size: 13, weight: .regular)
  private var rowHeight: CGFloat {
    size.rowHeight
  }

  private var iconSize: CGFloat {
    size.iconSize
  }

  var body: some View {
    Button(action: action) {
      HStack(spacing: 0) {
        icon
          .frame(width: iconSize, height: iconSize)
          .padding(.trailing, 8)

        Text(title)
          .font(Self.titleFont)
          .foregroundStyle(titleDimmed ? Color.secondary : Color.primary)
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)

        if nonProminentUnreadCount > 0 {
          SidebarNonProminentUnreadCount(count: nonProminentUnreadCount)
            .padding(.leading, 6)
        }

        if prominentUnreadCount > 0 {
          SidebarProminentUnreadBadge(count: prominentUnreadCount)
            .padding(.leading, 6)
        }
      }
      .frame(height: SidebarCollectionRow.paintedItemHeight(for: rowHeight))
      .padding(.leading, Theme.sidebarItemInnerSpacing)
      .padding(.trailing, Theme.sidebarItemOuterSpacing)
      .contentShape(.interaction, .rect(cornerRadius: Theme.sidebarItemRadius))
      .background(background)
      .padding(.horizontal, outerHorizontalPadding)
      .padding(.vertical, SidebarCollectionRow.itemVisualEdgeInset)
    }
    .buttonStyle(.plain)
    .help(title)
    .accessibilityLabel(title)
    .accessibilityValue(unreadAccessibilityValue)
    .accessibilityAddTraits(.isButton)
    .accessibilityAddTraits(selected ? .isSelected : [])
    .onHover { isHovered = $0 }
  }

  private var icon: some View {
    SidebarActionRowIcon(systemImage: systemImage, size: size)
  }

  private var outerHorizontalPadding: CGFloat {
    usesFullWidthCollectionLayout
      ? 8
      : -Theme.sidebarNativeDefaultEdgeInsets + 8
  }

  private var background: some View {
    RoundedRectangle(cornerRadius: Theme.sidebarItemRadius, style: .continuous)
      .fill(backgroundColor)
  }

  private var backgroundColor: Color {
    if selected {
      if colorScheme == .dark { return .white.opacity(0.1) }
      return .black.opacity(0.07)
    }
    if isHovered {
      if colorScheme == .dark { return .white.opacity(0.06) }
      return .black.opacity(0.05)
    }
    return .clear
  }

  private var unreadAccessibilityValue: Text {
    let prominentText = unreadAccessibilityDescription(
      count: prominentUnreadCount,
      singularLabel: "prominent unread chat"
    )
    let nonProminentText = unreadAccessibilityDescription(
      count: nonProminentUnreadCount,
      singularLabel: "other unread chat"
    )
    let parts = [prominentText, nonProminentText].compactMap { $0 }

    guard parts.isEmpty == false else { return Text("") }
    return Text("\(parts.joined(separator: " and ")) not in sidebar")
  }

  private func unreadAccessibilityDescription(count: Int, singularLabel: String) -> String? {
    guard count > 0 else { return nil }
    return "\(count) \(singularLabel)\(count == 1 ? "" : "s")"
  }
}

private struct SidebarGridRow: View {
  let avatars: [InlineKit.User]
  let selected: Bool
  let titleDimmed: Bool
  let size: SidebarItemSize
  var usesFullWidthCollectionLayout = false
  let hideAction: () -> Void
  let action: () -> Void

  @Environment(\.colorScheme) private var colorScheme
  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      SidebarGridRowContent(
        avatars: avatars,
        titleDimmed: titleDimmed,
        size: size,
        backgroundColor: backgroundColor,
        usesFullWidthCollectionLayout: usesFullWidthCollectionLayout
      )
    }
    .buttonStyle(.plain)
    .help("Grid")
    .accessibilityLabel("Grid")
    .accessibilityAddTraits(selected ? .isSelected : [])
    .onHover { isHovered = $0 }
    .contextMenu {
      Button("Hide Grid", systemImage: "eye.slash", action: hideAction)
    }
  }

  private var backgroundColor: Color {
    if selected {
      if colorScheme == .dark { return .white.opacity(0.1) }
      return .black.opacity(0.07)
    }
    if isHovered {
      if colorScheme == .dark { return .white.opacity(0.06) }
      return .black.opacity(0.05)
    }
    return .clear
  }
}

private struct SidebarGridRowContent: View {
  let avatars: [InlineKit.User]
  let titleDimmed: Bool
  let size: SidebarItemSize
  let backgroundColor: Color
  let usesFullWidthCollectionLayout: Bool

  var body: some View {
    HStack(spacing: 8) {
      SidebarActionRowIcon(systemImage: "square.grid.2x2", size: size)

      Text("Grid", comment: "Sidebar button for realtime voice rooms.")
        .font(.system(size: 13, weight: .regular))
        .foregroundStyle(titleDimmed ? Color.secondary : Color.primary)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)

      HStack(spacing: -6) {
        ForEach(avatars, id: \.id) { avatar in
          UserAvatar(user: avatar, size: 20)
            .transition(.scale(scale: 0.8).combined(with: .opacity))
        }
      }
      .animation(.smoothSnappy, value: avatars.map(\.id))
    }
    .frame(height: SidebarCollectionRow.paintedItemHeight(for: size.rowHeight))
    .padding(.leading, Theme.sidebarItemInnerSpacing)
    .padding(.trailing, Theme.sidebarItemOuterSpacing)
    .contentShape(.rect(cornerRadius: Theme.sidebarItemRadius))
    .background {
      RoundedRectangle(cornerRadius: Theme.sidebarItemRadius, style: .continuous)
        .fill(backgroundColor)
    }
    .padding(.horizontal, outerHorizontalPadding)
    .padding(.vertical, SidebarCollectionRow.itemVisualEdgeInset)
  }

  private var outerHorizontalPadding: CGFloat {
    usesFullWidthCollectionLayout
      ? 8
      : -Theme.sidebarNativeDefaultEdgeInsets + 8
  }
}

struct SidebarActionRowIcon: View {
  let systemImage: String
  let size: SidebarItemSize
  var weight: Font.Weight = .medium

  var body: some View {
    Image(systemName: systemImage)
      .font(.system(size: 13, weight: weight))
      .foregroundStyle(.secondary)
      .frame(width: size.iconSize, height: size.iconSize)
  }
}

private struct SidebarNonProminentUnreadCount: View, Equatable {
  let count: Int

  var body: some View {
    Text(String(count))
      .font(.system(size: 11, weight: .medium).monospacedDigit())
      .foregroundStyle(.tertiary)
      .lineLimit(1)
      .contentTransition(.numericText())
      .fixedSize(horizontal: true, vertical: false)
      .accessibilityHidden(true)
  }
}

private struct SidebarProminentUnreadBadge: View, Equatable {
  let count: Int

  private static let height: CGFloat = 16

  var body: some View {
    Text(String(count))
      .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
      .foregroundStyle(Color.white)
      .lineLimit(1)
      .contentTransition(.numericText())
      .padding(.horizontal, 5)
      .frame(minWidth: Self.height)
      .frame(height: Self.height)
      .fixedSize(horizontal: true, vertical: false)
      .background(Capsule().fill(Color(nsColor: Theme.prominentColor)))
      .accessibilityHidden(true)
  }
}

struct SidebarSeparatorRow: View {
  static let verticalSpacing: CGFloat = 6
  static let lineHeight: CGFloat = 1
  static let totalHeight = verticalSpacing * 2 + lineHeight

  var body: some View {
    Rectangle()
      .fill(Color.secondary.opacity(0.16))
      .frame(height: Self.lineHeight)
      .frame(height: Self.totalHeight)
      .padding(.leading, -Theme.sidebarNativeDefaultEdgeInsets + 14)
      .padding(.trailing, -Theme.sidebarNativeDefaultEdgeInsets + 14)
  }
}

private struct SpaceAvatar: View, Equatable {
  let space: Space
  var size: CGFloat = 18

  var body: some View {
    let text = SpaceAvatarContent.text(for: space)

    RoundedRectangle(cornerRadius: size * 0.4, style: .continuous)
      .fill(.quinary)
      .frame(width: size, height: size)
      .overlay {
        Text(text)
          .font(.system(size: size * SpaceAvatarContent.fontScale(for: text), weight: .semibold))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .minimumScaleFactor(0.75)
      }
      .fixedSize()
  }
}

private struct SidebarSpacePendingAction: Identifiable {
  let space: Space
  let action: SidebarSpaceDestructiveAction

  var id: String {
    "\(space.id)-\(action.title)"
  }
}

private enum SidebarSpaceDestructiveAction {
  case delete
  case leave

  static func action(for space: Space) -> SidebarSpaceDestructiveAction {
    space.creator == true ? .delete : .leave
  }

  var title: String {
    switch self {
    case .delete:
      "Delete Space"
    case .leave:
      "Leave Space"
    }
  }

  var shortTitle: String {
    switch self {
    case .delete:
      "Delete"
    case .leave:
      "Leave"
    }
  }

  var systemImage: String {
    switch self {
    case .delete:
      "trash"
    case .leave:
      "rectangle.portrait.and.arrow.right"
    }
  }

  var loadingTitle: String {
    switch self {
    case .delete:
      "Deleting space..."
    case .leave:
      "Leaving space..."
    }
  }

  var successTitle: String {
    switch self {
    case .delete:
      "Space deleted"
    case .leave:
      "Left space"
    }
  }

  var failureTitle: String {
    switch self {
    case .delete:
      "Failed to delete space"
    case .leave:
      "Failed to leave space"
    }
  }

  func confirmationMessage(spaceName: String) -> String {
    switch self {
    case .delete:
      "Delete \"\(spaceName)\"? This removes the space and its chats from your sidebar."
    case .leave:
      "Leave \"\(spaceName)\"? This removes the space and its chats from your sidebar."
    }
  }
}

private struct SidebarEmptyStateRow: View {
  let title: String
  let systemImage: String
  let actionTitle: String?
  let action: (() -> Void)?

  var body: some View {
    VStack(spacing: 7) {
      Image(systemName: systemImage)
        .font(.system(size: 16, weight: .regular))

      Text(title)
        .font(.system(size: 12, weight: .regular))

      if let actionTitle, let action {
        SidebarEmptyStateButton(title: actionTitle, action: action)
          .padding(.top, 1)
      }
    }
    .foregroundStyle(.tertiary)
    .frame(maxWidth: .infinity, alignment: .center)
    .padding(.vertical, 16)
  }
}

private struct SidebarEmptyStateButton: View {
  let title: String
  let action: () -> Void

  @Environment(\.colorScheme) private var colorScheme
  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 12, weight: .regular))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(background)
        .contentShape(.rect(cornerRadius: 7))
    }
    .buttonStyle(.plain)
    .help(title)
    .accessibilityLabel(title)
    .onHover { isHovered = $0 }
  }

  private var background: some View {
    RoundedRectangle(cornerRadius: 7, style: .continuous)
      .fill(isHovered ? hoverColor : idleColor)
  }

  private var idleColor: Color {
    colorScheme == .dark ? .white.opacity(0.06) : .black.opacity(0.04)
  }

  private var hoverColor: Color {
    colorScheme == .dark ? .white.opacity(0.12) : .black.opacity(0.08)
  }
}

private struct SidebarNewThreadRow: View {
  let size: SidebarItemSize
  let titleDimmed: Bool
  var usesFullWidthCollectionLayout = false
  var indentationLevel = 0
  var systemImage = "square.and.pencil"
  let action: () -> Void

  @Environment(\.colorScheme) private var colorScheme
  @State private var isHovered = false

  private static let titleFont: Font = .system(size: 13, weight: .regular)
  private var rowHeight: CGFloat {
    size.rowHeight
  }

  private var iconSize: CGFloat {
    size.iconSize
  }

  var body: some View {
    Button(action: action) {
      HStack(spacing: 0) {
        icon
          .frame(width: iconSize, height: iconSize)
          .padding(.trailing, 8)

        Text("New thread")
          .font(Self.titleFont)
          .foregroundStyle(titleDimmed ? Color.secondary : Color.primary)
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(height: SidebarCollectionRow.paintedItemHeight(for: rowHeight))
      .padding(
        .leading,
        Theme.sidebarItemInnerSpacing + CGFloat(indentationLevel) * (iconSize + 8)
      )
      .padding(.trailing, Theme.sidebarItemOuterSpacing)
      .contentShape(.interaction, .rect(cornerRadius: Theme.sidebarItemRadius))
      .background(background)
      .padding(.horizontal, outerHorizontalPadding)
      .padding(.vertical, SidebarCollectionRow.itemVisualEdgeInset)
    }
    .buttonStyle(.plain)
    .inlineTooltip(
      "New thread",
      shortcut: .command("N")
    )
    .accessibilityLabel("New Thread")
    .onHover { isHovered = $0 }
  }

  private var icon: some View {
    SidebarActionRowIcon(
      systemImage: systemImage,
      size: size,
      weight: .regular
    )
  }

  private var outerHorizontalPadding: CGFloat {
    usesFullWidthCollectionLayout
      ? 8
      : -Theme.sidebarNativeDefaultEdgeInsets + 8
  }

  private var background: some View {
    RoundedRectangle(cornerRadius: Theme.sidebarItemRadius, style: .continuous)
      .fill(isHovered ? hoverColor : .clear)
  }

  private var hoverColor: Color {
    colorScheme == .dark ? .white.opacity(0.07) : .black.opacity(0.05)
  }
}

private enum SidebarConnectionDisplayState: Equatable {
  case connecting
  case updating
  case waitingForNetwork
  case connected

  init?(_ state: RealtimeConnectionState) {
    switch state {
    case .connecting:
      self = .connecting
    case .updating:
      self = .updating
    case .connected:
      self = .connected
    }
  }

  var title: String {
    switch self {
    case .connecting:
      "Connecting..."
    case .updating:
      "Updating..."
    case .waitingForNetwork:
      "Waiting for network..."
    case .connected:
      "Connected"
    }
  }

  var showsSpinner: Bool {
    self != .connected
  }
}

private struct SidebarConnectionStatePill: View {
  let state: SidebarConnectionDisplayState

  var body: some View {
    HStack(spacing: 8) {
      if state.showsSpinner {
        SidebarConnectionSpinner()
        .transition(.opacity)
      }

      ZStack(alignment: .leading) {
        Text(state.title)
          .id(state.title)
          .font(.system(size: 13, weight: .regular))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
          .transition(.sidebarConnectionTextSwap)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .layoutPriority(1)
    }
    .padding(.horizontal, 10)
    .frame(maxWidth: .infinity, minHeight: 28, alignment: .center)
    .animation(.smoothSnappy, value: state)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(state.title)
  }
}

private extension AnyTransition {
  static var sidebarConnectionTextSwap: AnyTransition {
    .asymmetric(
      insertion: .modifier(
        active: SidebarConnectionTextTransition(y: 18, opacity: 0),
        identity: SidebarConnectionTextTransition(y: 0, opacity: 1)
      ),
      removal: .modifier(
        active: SidebarConnectionTextTransition(y: -18, opacity: 0),
        identity: SidebarConnectionTextTransition(y: 0, opacity: 1)
      )
    )
  }
}

private struct SidebarConnectionTextTransition: ViewModifier {
  let y: CGFloat
  let opacity: Double

  func body(content: Content) -> some View {
    content
      .opacity(opacity)
      .offset(y: y)
  }
}

private struct SidebarConnectionSpinner: View {
  @Environment(\.displayScale) private var displayScale
  @State private var angle: Double = 0

  var body: some View {
    Circle()
      .trim(from: 0.16, to: 0.86)
      .stroke(
        .tertiary,
        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
      )
      .frame(width: 12, height: 12)
      .rotationEffect(.degrees(angle))
      .onAppear {
        angle = 0
        withAnimation(.linear(duration: 0.5).repeatForever(autoreverses: false)) {
          angle = 360
        }
      }
  }

  private var lineWidth: CGFloat {
    2
  }
}
