import InlineKit
import InlineMacUI
import InlineUI
import Logger
import RealtimeV2
import SwiftUI

struct SidebarView: View {
  @Environment(\.dependencies) private var dependencies
  @Environment(\.mainWindowID) private var mainWindowID
  @Environment(\.nav) var nav
  @Environment(\.realtime) private var realtime
  @Environment(\.appearsActive) private var appearsActive
  @Environment(\.colorScheme) private var colorScheme
  @EnvironmentObject private var realtimeState: RealtimeState
  @EnvironmentObject private var updateInstallState: UpdateInstallState
  @ObservedObject private var settings = AppSettings.shared
  @State private var isHomeHovering = false
  @State private var isLocationHovering = false
  @State private var isArchiveVisible = false
  @State private var legacyApiState: RealtimeAPIState = Realtime.shared.apiState
  @State private var showConnectedState = false
  @State private var hideConnectedTask: Task<Void, Never>?
  @State private var pendingSpaceAction: SidebarSpacePendingAction?
  @State private var fetchingDialogSpaceIds = Set<Int64>()
  @State private var sidebarDrag = SidebarDragViewModel()
  @State private var ephemeralChat = SidebarEphemeralChatModel()
  @Environment(SidebarViewModel.self) private var viewModel
  private let isCollapsed: Bool

  init(isCollapsed: Bool = false) {
    self.isCollapsed = isCollapsed
  }

  var body: some View {
    sidebarContent
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
  }

  @ViewBuilder
  private var sidebarContent: some View {
    if #available(macOS 26.0, *) {
      // Safe area bar gives us the natural progressive blur background on macOS 26.0
      list
        .safeAreaBar(edge: .top) {
          topBar
        }
        .safeAreaBar(edge: .bottom) {
          bottomBar
        }
    } else {
      list
        .safeAreaInset(edge: .top) {
          topBar
        }
        .safeAreaInset(edge: .bottom) {
          bottomBar
        }
    }
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
    List {
      if settings.sidebarAsInbox {
        allChatsRow
      }

      if isArchiveVisible {
        Section("Archived") {
          chatRows
        }
      } else {
        chatRows
      }
    }
    .contentMargins(.top, 0, for: .scrollContent)
    .animation(.smoothSnappy, value: visibleItemAnimationKeys)
    .animation(.smoothSnappy, value: sidebarDrag.animationKey)
    .animation(.smoothSnappy, value: isArchiveVisible)
    .toolbar(removing: .sidebarToggle)
    .onChange(of: nav.currentRoute) { _, route in
      dependencies?.nav3ChatOpenPreloader?.cancelPendingOpenIfNeeded(for: route)
    }
    .onChange(of: selectedPeer, initial: true) { _, peer in
      syncEphemeralChat(peer)
    }
    .onChange(of: nav.selectedSpaceId, initial: true) { _, spaceId in
      syncSource(spaceId: spaceId)
      refreshEphemeralChatScope(selectedPeer)
      refreshSpaceIfNeeded(spaceId)
    }
    .onChange(of: settings.sidebarAsInbox, initial: true) { _, isEnabled in
      if isEnabled {
        isArchiveVisible = false
      }
      sidebarDrag.cancel()
      syncSource(spaceId: nav.selectedSpaceId)
      refreshEphemeralChatScope(selectedPeer)
    }
    .onChange(of: settings.includeSpaceChatsInHomeSidebar, initial: true) { _, includeSpaceChats in
      viewModel.setIncludeSpaceChatsInHome(includeSpaceChats)
      refreshEphemeralChatScope(selectedPeer)
    }
    .onChange(of: visibleItems.map(\.peerId)) { _, _ in
      reconcileEphemeralChat()
    }
    .onChange(of: viewModel.spaces.map(\.id)) { _, _ in
      validateSelectedSpace()
    }
    .onAppear {
      legacyApiState = realtime.apiState
      handleRealtimeConnectionStateChange(realtimeState.connectionState)
    }
    .onChange(of: sidebarNavigationSignature, initial: true) { _, _ in
      registerSidebarNavigation()
    }
    .onReceive(realtime.apiStatePublisher) { state in
      let oldState = legacyApiState
      legacyApiState = state
      handleLegacyApiStateChange(from: oldState, to: state)
    }
    .onChange(of: realtimeState.connectionState) { _, state in
      handleRealtimeConnectionStateChange(state)
    }
    .onEscapeKey("swiftui_sidebar_archive_escape", enabled: isArchiveVisible) {
      isArchiveVisible = false
    }
    .onDisappear {
      sidebarDrag.cancel()
      ephemeralChat.cancel()
      hideConnectedTask?.cancel()
      hideConnectedTask = nil
      unregisterSidebarNavigation()
    }
  }

  private var allChatsRow: some View {
    SidebarInboxActionRow(
      title: "Chats",
      systemImage: "text.bubble",
      selected: nav.currentRoute == .allChats || nav.currentRoute == .archivedChats,
      titleDimmed: sidebarTitlesDimmed,
      size: settings.showSidebarMessagePreview ? .large : .compact,
      trailingCount: viewModel.todayUnreadCount,
      action: openAllChats
    )
    .padding(.bottom, SidebarSeparatorRow.totalHeight)
    .overlay(alignment: .bottom) {
      SidebarSeparatorRow()
    }
    .listRowInsets(.zero)
    .listRowSeparator(.hidden)
    .listRowBackground(Color.clear)
  }

  @ViewBuilder
  private var chatRows: some View {
    if settings.sidebarAsInbox {
      let pinnedItems = sidebarDrag.displayItems(visiblePinnedItems, lane: .pinned)
      let normalItems = sidebarDrag.displayItems(visibleNormalSourceItems, lane: .normal)

      if pinnedItems.isEmpty == false {
        chatRows(for: visiblePinnedItems, lane: .pinned)
      }

      if normalItems.isEmpty == false {
        chatRows(for: visibleNormalSourceItems, lane: .normal, showsTopSeparator: pinnedItems.isEmpty == false)
      }
    } else {
      chatRows(for: visibleItems)
    }

    if settings.sidebarAsInbox {
      newThreadRow
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

      SidebarChatItemView(
        item: item,
        selected: isSelected,
        titleDimmed: sidebarTitlesDimmed,
        size: settings.showSidebarMessagePreview ? .large : .compact,
        showsCloseButton: settings.sidebarAsInbox && item.pinned == false,
        opensOnMouseDown: true,
        isTemporary: isTemporary,
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
    SidebarNewThreadRow(
      size: settings.showSidebarMessagePreview ? .large : .compact,
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
    // move it a bit higher up
    .padding(.top, -4)
    // distance it a bit from content
    .padding(.bottom, 12)
    // side spacing visually must match the items below
    .padding(.leading, SidebarTopBarMetrics.leadingPadding)
    .padding(.trailing, Theme.sidebarItemOuterSpacing)
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
    .help("Home")
    .accessibilityLabel("Home")
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
          .frame(maxWidth: .infinity, alignment: .leading)

        Image(systemName: "chevron.up.chevron.down")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.tertiary)
          .frame(width: SidebarTopBarMetrics.trailingAccessoryWidth, alignment: .center)
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
    .frame(maxWidth: .infinity, alignment: .leading)
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
    }

    if let selectedSpace {
      Divider()
      Section("Manage \(selectedSpace.displayName)") {
        selectedSpaceActions(selectedSpace)
      }
    }

    if viewModel.spaces.isEmpty == false || selectedSpace != nil {
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
  private var bottomBar: some View {
    VStack(spacing: 3) {
      // Temporarily hide the sidebar connection indicator.
      // if let state = sidebarConnectionState {
      //   SidebarConnectionStatePill(state: state)
      //     .padding(.horizontal, Theme.sidebarItemOuterSpacing + 4)
      //     .transition(.opacity)
      // }

      if updateInstallState.isReadyToInstall {
        installUpdateButton
          .transition(.opacity)
      }

      footerBar
    }
    .animation(.smoothSnappy, value: sidebarConnectionState)
    .animation(.smoothSnappy, value: updateInstallState.isReadyToInstall)
  }

  @ViewBuilder
  private var footerBar: some View {
    SidebarFooterView(
      isArchiveActive: isArchiveVisible,
      showsArchive: settings.sidebarAsInbox == false,
      showPreview: $settings.showSidebarMessagePreview,
      includeSpaceChatsInHome: $settings.includeSpaceChatsInHomeSidebar,
      sidebarAsInbox: $settings.sidebarAsInbox,
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
      onNewThread: {
        createNewThread()
      },
      onInvite: {
        nav.open(.inviteToSpace(spaceId: activeSpaceId))
      }
    )
  }

  @ViewBuilder
  private var installUpdateButton: some View {
    let button = Button {
      updateInstallState.install()
    } label: {
      Text("Update")
        .font(.system(size: 13, weight: .semibold))
    }
    .controlSize(.large)
    .buttonBorderShape(.capsule)
    .overlay {
      ButtonShineOverlay(active: true)
    }
    .clipShape(Capsule())
    .accessibilityLabel("Update")

    if #available(macOS 26.0, *) {
      button
        .buttonStyle(.glassProminent)
    } else {
      button
        .buttonStyle(.borderedProminent)
    }
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

  private var visibleItems: [SidebarViewModel.Item] {
    isArchiveVisible ? viewModel.archivedItems : viewModel.activeItems
  }

  private var visiblePinnedItems: [SidebarViewModel.Item] {
    visibleItems.filter(\.pinned)
  }

  private var visibleNormalItems: [SidebarViewModel.Item] {
    visibleItems.filter { $0.pinned == false }
  }

  private var visibleNormalSourceItems: [SidebarViewModel.Item] {
    guard let visibleTemporaryItem else { return visibleNormalItems }
    return visibleNormalItems + [visibleTemporaryItem]
  }

  private var visibleTemporaryItem: SidebarViewModel.Item? {
    guard settings.sidebarAsInbox else { return nil }
    guard isArchiveVisible == false else { return nil }
    guard let item = ephemeralChat.item else { return nil }
    guard visibleItems.contains(where: { $0.peerId == item.peerId }) == false else { return nil }
    return item
  }

  private var visibleItemAnimationKeys: [String] {
    var keys = visibleItems.map { "\($0.id.kind.rawValue)-\($0.id.rawValue)" }
    if let visibleTemporaryItem {
      keys.append("temporary-\(visibleTemporaryItem.id.kind.rawValue)-\(visibleTemporaryItem.id.rawValue)")
    }
    return keys
  }

  private var sidebarChatRowHeight: CGFloat {
    settings.showSidebarMessagePreview ? 44 : 30
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

  private var shouldShowEmptyState: Bool {
    visibleItems.isEmpty && isFetchingVisibleItems == false
  }

  private var isFetchingVisibleItems: Bool {
    guard settings.sidebarAsInbox == false else { return false }
    guard !isArchiveVisible else { return false }

    if let activeSpaceId {
      return fetchingDialogSpaceIds.contains(activeSpaceId)
    }

    return dependencies?.session.isFetchingSidebarChats == true
  }

  private var sidebarConnectionState: SidebarConnectionDisplayState? {
    guard !isCollapsed else { return nil }

    if legacyApiState == .waitingForNetwork {
      return .waitingForNetwork
    }

    if realtimeState.connectionState == .connected {
      return showConnectedState ? .connected : nil
    }

    guard let state = realtimeState.displayedConnectionState else { return nil }
    return SidebarConnectionDisplayState(state)
  }

  private var selectedPeer: Peer? {
    dependencies?.pendingChatPeer ?? nav.currentRoute.selectedPeer
  }

  private func openChat(_ item: SidebarViewModel.Item) {
    if let dependencies {
      dependencies.requestOpenChat(peer: item.peerId)
      return
    }

    nav.open(.chat(peer: item.peerId))
  }

  private func closeChat(_ item: SidebarViewModel.Item) {
    guard settings.sidebarAsInbox else { return }

    if isTemporaryItem(item) {
      ephemeralChat.cancel()
      return
    }

    guard let dependencies else { return }

    Task(priority: .userInitiated) {
      do {
        if try await dependencies.data.deleteThreadIfUntitledAndEmpty(peerId: item.peerId) {
          _ = await MainActor.run {
            dependencies.removeChatFromNavigation(peer: item.peerId)
          }
          return
        }
        _ = try await dependencies.realtimeV2.send(.updateDialogOpen(peerId: item.peerId, open: false))
      } catch {
        Log.shared.error("Failed to close chat in sidebar", error: error)
      }
    }
  }

  private func syncEphemeralChat(_ peer: Peer?) {
    guard settings.sidebarAsInbox else {
      ephemeralChat.cancel()
      return
    }
    guard let peer else { return }
    guard isPeerVisibleInSidebar(peer) == false else { return }

    ephemeralChat.setScope(
      peer: peer,
      spaceId: nav.selectedSpaceId,
      includeSpaceChatsInHome: settings.includeSpaceChatsInHomeSidebar
    )
  }

  private func refreshEphemeralChatScope(_ peer: Peer?) {
    guard settings.sidebarAsInbox else {
      ephemeralChat.cancel()
      return
    }

    if ephemeralChat.isScoped(
      spaceId: nav.selectedSpaceId,
      includeSpaceChatsInHome: settings.includeSpaceChatsInHomeSidebar
    ) == false {
      ephemeralChat.cancel()
    }

    syncEphemeralChat(peer)
  }

  private func reconcileEphemeralChat() {
    guard settings.sidebarAsInbox else {
      ephemeralChat.cancel()
      return
    }
    guard let peer = ephemeralChat.peer else { return }

    if isPeerVisibleInSidebar(peer) {
      ephemeralChat.cancel()
    }
  }

  private func isPeerVisibleInSidebar(_ peer: Peer) -> Bool {
    visibleItems.contains { $0.peerId == peer }
  }

  private func isTemporaryItem(_ item: SidebarViewModel.Item) -> Bool {
    visibleTemporaryItem?.peerId == item.peerId
  }

  private func persistTemporaryChat(_ item: SidebarViewModel.Item) {
    guard settings.sidebarAsInbox else { return }
    guard isTemporaryItem(item) else { return }
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

  private func applySidebarOrder(
    _ reorderedItems: [SidebarViewModel.Item],
    movedItem: SidebarViewModel.Item,
    newIndex: Int,
    sourceLane: SidebarOrderLane,
    targetLane: SidebarOrderLane
  ) {
    guard let dependencies else { return }
    let movedItemIsTemporary = isTemporaryItem(movedItem)
    let orderItems = movedItemIsTemporary ? reorderedItems : reorderedItems.filter { isTemporaryItem($0) == false }
    guard let orderIndex = orderItems.firstIndex(where: { $0.id == movedItem.id }) else { return }

    let previousIndex = orderIndex > orderItems.startIndex ? orderItems.index(before: orderIndex) : nil
    let nextIndex = orderItems.index(after: orderIndex)
    let previousItem = previousIndex.map { orderItems[$0] }
    let nextItem = nextIndex < orderItems.endIndex ? orderItems[nextIndex] : nil
    let updates = sidebarOrderUpdates(
      orderItems,
      movedItem: movedItem,
      previousItem: previousItem,
      nextItem: nextItem,
      lane: targetLane
    )

    let isCrossLaneMove = sourceLane != targetLane
    guard !updates.isEmpty || isCrossLaneMove || movedItemIsTemporary else { return }
    Task(priority: .userInitiated) {
      do {
        if movedItemIsTemporary {
          guard let movedOrder = updates.first(where: { $0.item.id == movedItem.id })?.order else { return }
          switch targetLane {
          case .normal:
            _ = try await dependencies.realtimeV2.send(.updateDialogOrder(
              peerId: movedItem.peerId,
              order: movedOrder,
              pinned: false
            ))
          case .pinned:
            _ = try await dependencies.realtimeV2.send(.updateDialogOrder(
              peerId: movedItem.peerId,
              pinnedOrder: movedOrder,
              pinned: true
            ))
          }
        } else if isCrossLaneMove {
          let movedOrder = updates.first { $0.item.id == movedItem.id }?.order ?? targetLane.order(for: movedItem)
          switch targetLane {
          case .normal:
            _ = try await dependencies.realtimeV2.send(.updateDialogOrder(
              peerId: movedItem.peerId,
              order: movedOrder,
              pinned: false
            ))
          case .pinned:
            _ = try await dependencies.realtimeV2.send(.updateDialogOrder(
              peerId: movedItem.peerId,
              pinnedOrder: movedOrder,
              pinned: true
            ))
          }
        }

        for update in updates {
          if (isCrossLaneMove || movedItemIsTemporary), update.item.id == movedItem.id {
            continue
          }

          switch targetLane {
          case .normal:
            _ = try await dependencies.realtimeV2.send(.updateDialogOrder(peerId: update.item.peerId, order: update.order))
          case .pinned:
            _ = try await dependencies.realtimeV2.send(.updateDialogOrder(peerId: update.item.peerId, pinnedOrder: update.order))
          }
        }
      } catch {
        Log.shared.error("Failed to reorder sidebar chat", error: error)
      }
    }
  }

  private func sidebarOrderUpdates(
    _ items: [SidebarViewModel.Item],
    movedItem: SidebarViewModel.Item,
    previousItem: SidebarViewModel.Item?,
    nextItem: SidebarViewModel.Item?,
    lane: SidebarOrderLane
  ) -> [(item: SidebarViewModel.Item, order: String)] {
    let previousOrder = lane.order(for: previousItem)
    let nextOrder = lane.order(for: nextItem)
    let hasCompleteLaneOrder = items.allSatisfy { lane.order(for: $0) != nil }

    if hasCompleteLaneOrder, canPlaceOrder(between: previousOrder, and: nextOrder) {
      let order = FractionalIndex.between(previousOrder, nextOrder)
      if order != lane.order(for: movedItem) {
        return [(movedItem, order)]
      }
      return []
    }

    return zip(items, FractionalIndex.sequence(count: items.count))
      .compactMap { item, order in
        lane.order(for: item) == order ? nil : (item, order)
      }
  }

  private func canPlaceOrder(between previousOrder: String?, and nextOrder: String?) -> Bool {
    switch (previousOrder, nextOrder) {
    case let (previous?, next?):
      previous < next
    case (nil, _?), (_?, nil), (nil, nil):
      true
    }
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

  private func createNewThread() {
    guard let dependencies else {
      nav.open(.newChat(spaceId: activeSpaceId))
      return
    }

    NewThreadAction.start(dependencies: dependencies, spaceId: activeSpaceId)
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

  private func refreshSpaceIfNeeded(_ spaceId: Int64?) {
    guard let spaceId else { return }
    guard let dependencies else { return }

    fetchingDialogSpaceIds.insert(spaceId)
    Task {
      defer {
        fetchingDialogSpaceIds.remove(spaceId)
      }

      do {
        try await dependencies.data.getSpace(spaceId: spaceId)
      } catch {
        Log.shared.error("Failed to refresh space \(spaceId)", error: error)
      }

      do {
        try await dependencies.realtimeV2.send(.getSpaceMembers(spaceId: spaceId))
      } catch {
        Log.shared.error("Failed to refresh space members \(spaceId)", error: error)
      }

      do {
        try await dependencies.data.getDialogs(spaceId: spaceId)
      } catch {
        Log.shared.error("Failed to refresh dialogs for space \(spaceId)", error: error)
      }
    }
  }

  private func navigateChat(offset: Int) {
    guard visibleItems.isEmpty == false else { return }

    let currentIndex = selectedPeer.flatMap { peer in
      visibleItems.firstIndex { $0.peerId == peer }
    } ?? -1

    let targetIndex = currentIndex + offset
    guard visibleItems.indices.contains(targetIndex) else { return }

    openChat(visibleItems[targetIndex])
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

  private func syncSource(spaceId: Int64?) {
    let mode = settings.sidebarAsInbox ? SidebarViewModel.ContentMode.inbox : .chatList

    if let spaceId {
      viewModel.selectSpace(spaceId, mode: mode)
    } else {
      viewModel.selectHome(mode: mode)
    }
  }

  private func validateSelectedSpace() {
    guard let spaceId = nav.selectedSpaceId else { return }
    guard viewModel.hasSpace(id: spaceId) == false else { return }
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

  private func handleLegacyApiStateChange(from oldState: RealtimeAPIState, to state: RealtimeAPIState) {
    if state == .waitingForNetwork {
      hideConnectedTask?.cancel()
      hideConnectedTask = nil
      showConnectedState = false
      return
    }

    if oldState == .waitingForNetwork, state == .connected, realtimeState.connectionState == .connected {
      showConnectedTemporarily()
    }
  }

  private func showConnectedTemporarily() {
    guard legacyApiState != .waitingForNetwork else { return }

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
    .environmentObject(RealtimeState())
    .environmentObject(UpdateInstallState())
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
  static let leadingPadding = Theme.sidebarItemOuterSpacing + 3
  static let trailingAccessoryWidth: CGFloat = 14
}

private struct SidebarInboxActionRow: View {
  let title: String
  let systemImage: String
  let selected: Bool
  let titleDimmed: Bool
  let size: SidebarItemSize
  let trailingCount: Int
  let action: () -> Void

  @Environment(\.colorScheme) private var colorScheme
  @State private var isHovered = false

  private static let titleFont: Font = .system(size: 13, weight: .regular)
  private static let innerPaddingHorizontal = 6.0
  private static let compactIconSize = 22.0
  private static let largeIconSize = 32.0

  private var rowHeight: CGFloat {
    switch size {
    case .compact:
      30
    case .large:
      44
    }
  }

  private var iconSize: CGFloat {
    switch size {
    case .compact:
      Self.compactIconSize
    case .large:
      Self.largeIconSize
    }
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

        if trailingCount > 0 {
          Text(String(trailingCount))
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.leading, 6)
        }
      }
      .frame(height: rowHeight)
      .padding(.horizontal, Self.innerPaddingHorizontal)
      .contentShape(.interaction, .rect(cornerRadius: Theme.sidebarItemRadius))
      .background(background)
      .padding(.horizontal, -Theme.sidebarNativeDefaultEdgeInsets + 8)
    }
    .buttonStyle(.plain)
    .help(title)
    .accessibilityLabel(title)
    .accessibilityAddTraits(.isButton)
    .accessibilityAddTraits(selected ? .isSelected : [])
    .onHover { isHovered = $0 }
  }

  private var icon: some View {
    Image(systemName: systemImage)
      .font(.system(size: 13, weight: .medium))
      .foregroundStyle(.secondary)
      .frame(width: iconSize, height: iconSize)
      .background {
        if size == .large {
          Circle()
            .fill(.quinary)
        }
      }
  }

  private var background: some View {
    RoundedRectangle(cornerRadius: Theme.sidebarItemRadius, style: .continuous)
      .fill(backgroundColor)
  }

  private var backgroundColor: Color {
    if selected {
      colorScheme == .dark ? .white.opacity(0.1) : .black.opacity(0.07)
    } else if isHovered {
      colorScheme == .dark ? .white.opacity(0.06) : .black.opacity(0.05)
    } else {
      .clear
    }
  }
}

private struct SidebarSeparatorRow: View {
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
  let action: () -> Void

  @Environment(\.colorScheme) private var colorScheme
  @State private var isHovered = false

  private static let titleFont: Font = .system(size: 13, weight: .regular)
  private static let innerPaddingHorizontal = 6.0
  private static let compactIconSize = 22.0
  private static let largeIconSize = 32.0

  private var rowHeight: CGFloat {
    switch size {
    case .compact:
      30
    case .large:
      44
    }
  }

  private var iconSize: CGFloat {
    switch size {
    case .compact:
      Self.compactIconSize
    case .large:
      Self.largeIconSize
    }
  }

  var body: some View {
    Button(action: action) {
      HStack(spacing: 0) {
        icon
          .frame(width: iconSize, height: iconSize)
          .padding(.trailing, 8)

        Text("New thread")
          .font(Self.titleFont)
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .foregroundStyle(.secondary)
      .frame(height: rowHeight)
      .padding(.horizontal, Self.innerPaddingHorizontal)
      .contentShape(.interaction, .rect(cornerRadius: Theme.sidebarItemRadius))
      .background(background)
      .padding(.horizontal, -Theme.sidebarNativeDefaultEdgeInsets + 8)
    }
    .buttonStyle(.plain)
    .help("New Thread")
    .accessibilityLabel("New Thread")
    .onHover { isHovered = $0 }
    .animation(.smoothSnappy, value: size)
  }

  @ViewBuilder
  private var icon: some View {
    if size == .large {
      Circle()
        .fill(.quinary)
        .overlay {
          Image(systemName: "square.and.pencil")
            .font(.system(size: iconSize * 0.42, weight: .regular))
            .foregroundStyle(.secondary)
        }
    } else {
      Image(systemName: "square.and.pencil")
        .font(.system(size: 13, weight: .regular))
    }
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
