import InlineKit
import InlineUI
import SwiftUI
import os.signpost

struct ChatRouteView: View {
  let peer: Peer
  private static let signpostLog = OSLog(subsystem: "InlineMac", category: "PointsOfInterest")

  @Environment(\.appDatabase) private var db
  @Environment(\.dependencies) private var dependencies
  @Environment(\.mainWindowID) private var mainWindowID
  @Environment(\.nav) private var nav

  @ObservedObject private var botPresenceController = BotPresenceController.shared
  @ObservedObject private var settings = AppSettings.shared
  @State private var chatToolbarState = ChatToolbarState()
  @State private var botChatSettingsCoordinator: BotChatSettingsCoordinator
  @State private var toolbarDialog: Dialog?
  @State private var navigationTitle = ""
  @State private var userGroupMentionTarget: UserGroupMentionTarget?

  init(peer: Peer) {
    self.peer = peer
    _botChatSettingsCoordinator = State(initialValue: BotChatSettingsCoordinator(peer: peer))
  }

  private var fallbackTitle: String {
    peer.isThread ? "Chat" : "Direct Message"
  }

  private var followPresentation: ChatToolbarFollowPresentation? {
    guard peer.isThread else { return nil }
    return ChatToolbarFollowPresentation(isFollowing: toolbarDialog?.isFollowingThread == true)
  }

  var body: some View {
    if let dependencies {
      let dependencies = dependencies.with(nav3: nav)

      AppKitRouteViewController<ChatViewAppKit>(
        make: {
          let signpostID = OSSignpostID(log: Self.signpostLog)
          var payloadLabel = "cold"
          os_signpost(
            .begin,
            log: Self.signpostLog,
            name: "ChatRouteMakeAppKit",
            signpostID: signpostID,
            "%{public}s",
            String(describing: peer)
          )
          defer {
            os_signpost(
              .end,
              log: Self.signpostLog,
              name: "ChatRouteMakeAppKit",
              signpostID: signpostID,
              "%{public}s",
              payloadLabel
            )
          }

          let preparedPayload = dependencies.nav3ChatOpenPreloader?.consumePreparedPayload(for: peer)
          payloadLabel = preparedPayload == nil ? "cold" : "prepared"
          return ChatViewAppKit(
            peerId: peer,
            preparedPayload: preparedPayload,
            dependencies: dependencies,
            toolbarState: chatToolbarState,
            onDialogChange: { dialog in
              toolbarDialog = dialog
            }
          )
        },
        dismantle: { controller in
          controller.dispose()
        }
      )
      .ignoresSafeArea(.all, edges: .vertical)
      // MessageListAppKit captures its render style at construction. Replacing the
      // controller avoids mutating a live message renderer when the setting changes.
      .id("chat-\(peer.toString())-\(settings.messageRenderStyle.rawValue)")
      .frame(minWidth: Theme.chatViewMinWidth, maxWidth: .infinity, maxHeight: .infinity)
      .chatScrollEdgeEffect()
      .navigationTitle(navigationTitle.isEmpty ? fallbackTitle : navigationTitle)
      .commandBar {
        if peer.isThread {
          CommandBarAction(
            "Rename Thread",
            systemImage: "pencil",
            id: "rename",
            keywords: ["rename", "renaming", "title", "thread", "chat", "name"],
            typeLabel: "Chat",
            priority: 30
          ) {
            if MainWindowOpenCoordinator.shared.renameThread() == false {
              NotificationCenter.default.post(name: .renameThread, object: nil)
            }
          }
        }

        if let followPresentation {
          CommandBarAction(
            followPresentation.title,
            systemImage: followPresentation.systemImage,
            id: "follow",
            keywords: ["follow", "unfollow", "thread", "messages", "sidebar"],
            typeLabel: "Chat",
            priority: 20
          ) {
            ChatToolbarFollowButton.toggleFollowMode(
              peer: peer,
              isFollowing: followPresentation.isFollowing
            )
          }
        }
      }
      .onChange(of: peer.toString(), initial: true) { oldPeer, newPeer in
        navigationTitle = fallbackTitle
        if oldPeer != newPeer {
          toolbarDialog = nil
          chatToolbarState.dismissPresentation()
          botChatSettingsCoordinator.cancel()
          botChatSettingsCoordinator = BotChatSettingsCoordinator(peer: peer)
        }
        syncChatMenuContext(dependencies: dependencies)
      }
      .onChange(of: toolbarDialog) { _, _ in
        syncChatMenuContext(dependencies: dependencies)
      }
      .onEscapeKey(
        "chat_route_popover_escape_\(peer.toString())",
        enabled: chatToolbarState.presentation?.isPopover == true
      ) {
        chatToolbarState.dismissPresentation()
      }
      .task(id: peer.toString(), priority: .utility) {
        BotPresenceController.shared.setContext(peer: peer, realtimeV2: dependencies.realtimeV2)
        await ensureToolbarParticipantsLoaded(dependencies: dependencies)
        botChatSettingsCoordinator.startObservingDiscoveryScope(in: dependencies.database)
        await botChatSettingsCoordinator.warmUp()
      }
      .onDisappear {
        BotPresenceController.shared.clearContext(peer: peer)
        botChatSettingsCoordinator.cancel()
        if let mainWindowID {
          MainWindowOpenCoordinator.shared.unregisterChatMenuContext(id: mainWindowID, peer: peer)
        }
      }
      .onReceive(
        NotificationCenter.default
          .publisher(for: .userGroupMentionTapped)
      ) { notification in
        guard var target = notification.userInfo?["target"] as? UserGroupMentionTarget else { return }
        if target.spaceId == nil {
          target.spaceId = nav.selectedSpaceId
        }
        userGroupMentionTarget = target
      }
      .sheet(item: $userGroupMentionTarget) { target in
        UserGroupMembersSheet(target: target)
      }
      .toolbar {
        let mainItem =
          MacToolbarItem(placement: .navigation, priority: .high, label: "") {
            ChatRouteTitleBar(peer: peer, db: db, contextSpaceId: nav.selectedSpaceId) { title in
              navigationTitle = title
            }
            .macToolbarLayout(toolbarLayout)
            .id(peer.toString())
            .modifier(ChatToolbarTranslationPresentations(
              peer: peer,
              toolbarState: chatToolbarState,
              anchor: .title,
              listensForPrompt: true
            ))
            .modifier(ChatToolbarParticipantsTitlePresentations(
              peer: peer,
              dependencies: dependencies,
              toolbarState: chatToolbarState
            ))
            .modifier(ChatToolbarNotificationTitlePresentations(
              peer: peer,
              db: dependencies.database,
              toolbarState: chatToolbarState
            ))
            .onDisappear {
              chatToolbarState.handleTitleDisappear()
            }
          }

        if #available(macOS 26.0, *) {
          mainItem.sharedBackgroundVisibility(.hidden)
        } else {
          mainItem
        }

        if #available(macOS 26.0, *) {
          ToolbarSpacer(.flexible)
        }

        if botPresenceController.toolbarItem(for: peer) != nil {
          ToolbarItem {
            BotPresenceToolbarButton(
              peer: peer,
              controller: botPresenceController
            )
            .macToolbarLayout(toolbarLayout)
            .id(peer.toString())
          }

          if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed)
          }
        }

        if botChatSettingsCoordinator.isToolbarVisible {
          ToolbarItem {
            BotChatSettingsToolbarButton(
              coordinator: botChatSettingsCoordinator,
              toolbarState: chatToolbarState
            )
            .macToolbarLayout(toolbarLayout)
            .id("bot-settings-\(peer.toString())")
          }

          if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed)
          }
        }

        if settings.translationUIEnabled, peer.isThread {
          ToolbarItem {
            ChatToolbarTranslationButton(peer: peer, toolbarState: chatToolbarState)
          }

          if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed)
          }
        }

        if peer.isThread {
          ToolbarItem {
            ChatToolbarParticipantsButton(
              peer: peer,
              dependencies: dependencies,
              toolbarState: chatToolbarState
            )
            .macToolbarLayout(toolbarLayout)
            .id("participants-\(peer.toString())")
          }

          if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed)
          }

          ToolbarItem {
            ChatToolbarShareButton(
              peer: peer,
              dependencies: dependencies,
              toolbarState: chatToolbarState
            )
            .macToolbarLayout(toolbarLayout)
            .id("share-\(peer.toString())")
          }

          if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed)
          }
        }

        ToolbarItem {
          ChatToolbarNotificationButton(
            peer: peer,
            db: dependencies.database,
            toolbarState: chatToolbarState
          )
          .id(peer.id)
        }

        if let followPresentation {
          ToolbarItem {
            ChatToolbarFollowButton(
              peer: peer,
              isFollowing: followPresentation.isFollowing
            )
            .id("follow-\(peer.toString())")
          }
        }

        if #available(macOS 26.0, *) {
          ToolbarSpacer(.fixed)
        }

        if case .user = peer {
          ToolbarItem {
            NudgeButton(peer: peer)
              .id(peer.id)
          }

          if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed)
          }
        }

        if settings.translationUIEnabled, !peer.isThread {
          ToolbarItem {
            ChatToolbarTranslationButton(peer: peer, toolbarState: chatToolbarState)
          }
        }

        ToolbarItem {
          ChatToolbarMenuButton(peer: peer, dependencies: dependencies)
            .id(peer.id)
        }
      }
    } else {
      RoutePlaceholderView(
        title: "Missing App Dependencies",
        systemImage: "exclamationmark.triangle"
      )
    }
  }

  private func syncChatMenuContext(dependencies: AppDependencies) {
    guard let mainWindowID else { return }
    let dialog = toolbarDialog
    let isUnread = (dialog?.unreadCount ?? 0) > 0 || dialog?.unreadMark == true

    MainWindowOpenCoordinator.shared.registerChatMenuContext(
      id: mainWindowID,
      context: ChatMenuContext(
        peer: peer,
        isUnread: isUnread,
        isFollowing: dialog?.isFollowingThread == true,
        isOpenInSidebar: dialog?.open == true && dialog?.archived != true && dialog?.chatListHidden != true,
        isPinned: dialog?.pinned == true,
        isArchived: dialog?.archived == true,
        canRename: peer.isThread,
        perform: { command in
          performChatMenuCommand(command, dialog: dialog, dependencies: dependencies)
        }
      )
    )
  }

  private func performChatMenuCommand(
    _ command: ChatMenuCommand,
    dialog: Dialog?,
    dependencies: AppDependencies
  ) {
    switch command {
    case .showInfo:
      dependencies.openChatInfo(peer: peer)
    case .copyLink:
      ChatMenuActions.copyLink(for: peer)
    case .openNewTab:
      MainWindowOpenCoordinator.shared.openTab(.chat(peer: peer))
    case .openNewWindow:
      MainWindowOpenCoordinator.shared.openNewWindow(.chat(peer: peer))
    case .rename:
      if MainWindowOpenCoordinator.shared.renameThread() == false {
        NotificationCenter.default.post(name: .renameThread, object: nil)
      }
    case .toggleRead:
      Task(priority: .userInitiated) {
        do {
          let isUnread = (dialog?.unreadCount ?? 0) > 0 || dialog?.unreadMark == true
          if isUnread {
            guard let chatId = dialog?.chatId else {
              await MainActor.run { ToastCenter.shared.showError("Failed to update read status") }
              return
            }
            UnreadManager.shared.readAll(peer, chatId: chatId)
          } else {
            try await dependencies.realtimeV2.send(.markAsUnread(peerId: peer))
          }
        } catch {
          await MainActor.run { ToastCenter.shared.showError("Failed to update read status") }
        }
      }
    case .toggleFollow:
      ChatToolbarFollowButton.toggleFollowMode(
        peer: peer,
        isFollowing: dialog?.isFollowingThread == true
      )
    case .openInSidebar:
      ChatMenuActions.openInSidebar(
        peer: peer,
        isHidden: dialog?.chatListHidden == true,
        dependencies: dependencies
      )
    case .togglePin:
      ChatMenuActions.togglePin(
        peer: peer,
        isPinned: dialog?.pinned == true,
        spaceID: dialog?.spaceId
      )
    case .toggleArchive:
      ChatMenuActions.toggleArchive(
        peer: peer,
        isArchived: dialog?.archived == true,
        spaceID: dialog?.spaceId,
        dependencies: dependencies
      )
    }
  }

  private func ensureToolbarParticipantsLoaded(dependencies: AppDependencies) async {
    guard case let .thread(chatId) = peer else { return }
    await ChatParticipantsWithMembersViewModel.ensureParticipantsLoaded(
      db: dependencies.database,
      chatId: chatId
    )
  }

  private var toolbarLayout: MacToolbarLayout {
    settings.toolbarStyle.layout
  }
}

extension View {
  @ViewBuilder
  func chatScrollEdgeEffect() -> some View {
    if #available(macOS 27.0, *) {
      scrollEdgeEffectStyle(.hard, for: .top)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    } else {
      self
    }
  }
}
