import InlineKit
import InlineUI
import os.signpost
import SwiftUI

struct ChatRouteView: View {
  let peer: InlineKit.Peer
  private static let signpostLog = OSLog(subsystem: "InlineMac", category: "PointsOfInterest")

  @Environment(\.appDatabase) private var db
  @Environment(\.dependencies) private var dependencies
  @Environment(\.mainWindowID) private var mainWindowID
  @Environment(\.nav) private var nav

  @ObservedObject private var botPresenceController = BotPresenceController.shared
  @ObservedObject private var settings = AppSettings.shared
  @State private var chatToolbarState = ChatToolbarState()
  /// Per-chat models, swapped when a stable route moves to another chat (see `PeerBoundModel`).
  @State private var botChatSettingsBox: PeerBoundBox<BotChatSettingsCoordinator>
  @StateObject private var agentThreadToolbarHost: PeerBoundObject<AgentThreadToolbarModel>
  /// The chat this route last showed, so a stable route can leave it when the peer changes.
  @State private var shownPeer: Peer?
  @State private var toolbarDialog: InlineKit.Dialog?
  @State private var navigationTitle = ""
  @State private var userGroupMentionTarget: UserGroupMentionTarget?
  @State private var botAgentMentionTarget: BotAgentMentionTarget?

  init(peer: InlineKit.Peer) {
    self.peer = peer
    _botChatSettingsBox = State(initialValue: PeerBoundBox(release: { $0.cancel() }))
    _agentThreadToolbarHost = StateObject(wrappedValue: PeerBoundObject(
      peer: peer,
      model: AgentThreadToolbarModel(peer: peer),
      release: { $0.cancel() }
    ))
  }

  private var agentThreadToolbarModel: AgentThreadToolbarModel {
    agentThreadToolbarHost.model(for: peer) { AgentThreadToolbarModel(peer: $0) }
  }

  private var botChatSettingsCoordinator: BotChatSettingsCoordinator {
    botChatSettingsBox.model(for: peer) { BotChatSettingsCoordinator(peer: $0) }
  }

  private var windowTitle: String {
    if chatToolbarState.isContentUnavailable {
      return ChatUnavailableCopy.title(for: peer)
    }
    return navigationTitle.isEmpty ? fallbackTitle : navigationTitle
  }

  private var fallbackTitle: String {
    peer.isThread ? "Chat" : "Direct Message"
  }

  private var isOwnedBotChat: Bool {
    guard let userId = peer.asUserId() else { return false }
    return SidebarAgents.shared.isOwnedBot(userId)
  }

  private var followPresentation: ChatToolbarFollowPresentation? {
    guard peer.isThread else { return nil }
    return ChatToolbarFollowPresentation(isFollowing: toolbarDialog?.isFollowingThread == true)
  }

  var body: some View {
    if let dependencies {
      let dependencies = dependencies.with(nav3: nav)

      chatHost(dependencies: dependencies)
      .ignoresSafeArea(.all, edges: .vertical)
      // MessageListAppKit captures its render style at construction. Replacing the
      // controller avoids mutating a live message renderer when the setting changes.
      // The stable route keeps its host across chats and swaps the chat inside it.
      .id(
        "chat-\(settings.stableChatRouteEnabled ? "route" : peer.toString())-\(settings.messageRenderStyle.rawValue)-rich:\(settings.richContentRendererEnabled)-inline-math:\(settings.richTextInlineMathEnabled)-widgets:\(settings.messageWidgetsEnabled)"
      )
      .frame(minWidth: Theme.chatViewMinWidth, maxWidth: .infinity, maxHeight: .infinity)
      .chatScrollEdgeEffect()
      .navigationTitle(windowTitle)
      .commandBar {
        if peer.isThread || isOwnedBotChat, !chatToolbarState.isContentUnavailable {
          CommandBarAction(
            peer.isThread ? "Rename Thread" : "Rename Bot",
            systemImage: "pencil",
            id: "rename",
            keywords: ["rename", "renaming", "title", "thread", "chat", "name", "bot"],
            typeLabel: "Chat",
            priority: 30
          ) {
            if MainWindowOpenCoordinator.shared.renameThread() == false {
              NotificationCenter.default.post(name: .renameThread, object: nil)
            }
          }
        }

        if let followPresentation, !chatToolbarState.isContentUnavailable {
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
        if oldPeer == newPeer {
          navigationTitle = fallbackTitle
        } else {
          // Only a stable route outlives its chat; a per-chat route is rebuilt instead. The title
          // bar reports the new chat's title itself, so the window title never falls back to
          // "Chat" in between.
          if let shownPeer, shownPeer != peer {
            leaveChat(shownPeer)
          }
          toolbarDialog = nil
          userGroupMentionTarget = nil
          botAgentMentionTarget = nil
          chatToolbarState.dismissPresentation()
        }
        shownPeer = peer
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
        agentThreadToolbarModel.start(database: dependencies.database)
        // Cached run state renders immediately; this reconciles it.
        await AgentWorkStateStore.shared.refresh(peer: peer)
        await ensureToolbarParticipantsLoaded(dependencies: dependencies)
        botChatSettingsCoordinator.startObservingDiscoveryScope(in: dependencies.database)
      }
      .task(id: toolbarDialog?.id, priority: .utility) {
        guard toolbarDialog != nil else { return }
        BotPresenceController.shared.setContext(peer: peer, realtimeV2: dependencies.realtimeV2)
        await botChatSettingsCoordinator.warmUp()
      }
      .onDisappear {
        leaveChat(peer)
        agentThreadToolbarModel.cancel()
        botChatSettingsCoordinator.cancel()
        shownPeer = nil
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
      .onReceive(
        NotificationCenter.default.publisher(for: .botAgentMentionTapped)
      ) { notification in
        guard let target = notification.userInfo?["target"] as? BotAgentMentionTarget,
              target.peer == peer
        else { return }
        botAgentMentionTarget = target
      }
      .sheet(item: $botAgentMentionTarget) { target in
        BotAgentProfileSheet(target: target)
      }
      .toolbar {
        let mainItem =
          MacToolbarItem(placement: .navigation, priority: .high, label: "") {
            if chatToolbarState.isContentUnavailable {
              ChatUnavailableTitleBar(peer: peer)
                .macToolbarLayout(toolbarLayout)
            } else {
              ChatRouteTitleBar(
                peer: peer,
                db: db,
                contextSpaceId: nav.selectedSpaceId,
                agentThreadToolbarModel: agentThreadToolbarModel,
                onTitleChange: { title in
                  navigationTitle = title
                }
              )
              .macToolbarLayout(toolbarLayout)
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
              .modifier(ChatToolbarLinkAccessPromptPresentation(
                toolbarState: chatToolbarState,
                anchor: .title
              ))
              .onDisappear {
                chatToolbarState.handleTitleDisappear()
              }
            }
          }

        if #available(macOS 26.0, *) {
          mainItem.sharedBackgroundVisibility(.hidden)
        } else {
          mainItem
        }

        if #available(macOS 26.0, *) {
          ToolbarSpacer(.flexible)
        } else {
          ToolbarItem {
            Spacer()
          }
        }

        // Actions need a readable chat; a private thread you can't open keeps
        // only its title.
        if !chatToolbarState.isContentUnavailable {
          if botPresenceController.toolbarItem(for: peer) != nil {
            ToolbarItem {
              BotPresenceToolbarButton(
                peer: peer,
                controller: botPresenceController
              )
              .macToolbarLayout(toolbarLayout)
            }

            if #available(macOS 26.0, *) {
              ToolbarSpacer(.fixed)
            }
          }

          if botChatSettingsCoordinator.isToolbarVisible || agentThreadToolbarModel.context != nil {
            ToolbarItem {
              BotChatSettingsToolbarButton(
                coordinator: botChatSettingsCoordinator,
                agentThreadModel: agentThreadToolbarModel,
                toolbarState: chatToolbarState,
                updateAgentContext: { context in
                  _ = try await dependencies.realtimeV2.send(.updateChatInfo(
                    chatID: agentThreadToolbarModel.chatID,
                    title: nil,
                    emoji: nil,
                    agentContext: context
                  ))
                }
              )
              .macToolbarLayout(toolbarLayout)
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
          }

          if let followPresentation {
            ToolbarItem {
              ChatToolbarFollowButton(
                peer: peer,
                isFollowing: followPresentation.isFollowing
              )
            }
          }

          if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed)
          }

          if case .user = peer {
            ToolbarItem {
              NudgeButton(peer: peer)
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
          }
        }
      }
    } else {
      RoutePlaceholderView(
        title: "Missing App Dependencies",
        systemImage: "exclamationmark.triangle"
      )
    }
  }

  @ViewBuilder
  private func chatHost(dependencies: AppDependencies) -> some View {
    if settings.stableChatRouteEnabled {
      AppKitRouteViewController<ChatRouteContainerController>(
        make: { ChatRouteContainerController() },
        update: { container in
          container.show(peer: peer) { makeChatView(dependencies: dependencies) }
        },
        dismantle: { container in
          container.dispose()
        }
      )
    } else {
      AppKitRouteViewController<ChatViewAppKit>(
        make: { makeChatView(dependencies: dependencies) },
        dismantle: { controller in
          controller.dispose()
        }
      )
    }
  }

  private func makeChatView(dependencies: AppDependencies) -> ChatViewAppKit {
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
  }

  /// Ends the per-chat registrations for `chatPeer`: on disappear, and when a stable route moves on.
  private func leaveChat(_ chatPeer: Peer) {
    BotPresenceController.shared.clearContext(peer: chatPeer)
    if let mainWindowID {
      MainWindowOpenCoordinator.shared.unregisterChatMenuContext(id: mainWindowID, peer: chatPeer)
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
        canPin: dialog?.pinned == true || dialog?.folderId == nil,
        isArchived: dialog?.archived == true,
        canRename: peer.isThread || isOwnedBotChat,
        perform: { command in
          performChatMenuCommand(command, dialog: dialog, dependencies: dependencies)
        }
      )
    )
  }

  private func performChatMenuCommand(
    _ command: ChatMenuCommand,
    dialog: InlineKit.Dialog?,
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
            || (dialog?.unreadMentionsCount ?? 0) > 0
          if isUnread {
            guard let chatId = dialog?.chatId else {
              await MainActor.run { ToastCenter.shared.showError("Failed to update read status") }
              return
            }
            UnreadManager.shared.markChatRead(peer, chatId: chatId)
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
      ChatMenuActions.openInSidebar(peer: peer)
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
