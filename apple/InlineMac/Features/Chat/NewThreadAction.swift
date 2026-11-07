import InlineKit
import InlineProtocol
import Logger
import RealtimeV2

@MainActor
enum NewThreadAction {
  static func start(dependencies: AppDependencies, nav: Nav3) {
    if #available(macOS 26.0, *) {
      dependencies.nav3ChatOpenPreloader?.cancelPendingOpen()
      nav.openNewThreadComposer()
      return
    }

    start(dependencies: dependencies, spaceId: nav.selectedSpaceId)
  }

  static func start(
    dependencies: AppDependencies,
    spaceId: Int64?,
    title: String = "",
    destinationFolderId: Int64? = nil
  ) {
    ToastCenter.shared.showLoading("Creating thread")

    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedTitle = trimmedTitle.isEmpty ? "" : trimmedTitle

    Task {
      guard let currentUserId = dependencies.auth.currentUserId else {
        await MainActor.run {
          ToastCenter.shared.dismiss()
          ToastCenter.shared.showError("You're signed out. Please log in again.")
        }
        return
      }

      do {
        let chatId = try await dependencies.realtimeV2.createThreadLocally(
          title: resolvedTitle,
          emoji: nil,
          isPublic: false,
          spaceId: spaceId,
          participants: [currentUserId]
        )
        let peer: InlineKit.Peer = .thread(id: chatId)

        if let destinationFolderId {
          await dependencies.realtimeV2.sendQueued(.updateDialogOrder(
            peerId: peer,
            pinned: false,
            destination: .folder(destinationFolderId),
            requiresChatCreated: true
          ))
        } else {
          await dependencies.realtimeV2.sendQueued(
            .updateDialogOpen(peerId: peer, open: true, requiresChatCreated: true)
          )
        }

        await MainActor.run {
          ToastCenter.shared.dismiss()
          dependencies.requestOpenChat(peer: peer)
        }
      } catch {
        await MainActor.run {
          ToastCenter.shared.dismiss()
          ToastCenter.shared.showError("Failed to create thread.")
        }
      }
    }
  }

  /// Starts a thread nested under a sidebar chat and opens it, ready for a
  /// message. It inherits the parent's access, like a reply thread. On a
  /// direct chat with an agent, `agentBotUserId` adds the agent so it
  /// answers; `bindsAgent` also adds its preset, which only the bot's owner
  /// can set.
  static func startSubthread(
    dependencies: AppDependencies,
    parentChatId: Int64,
    agentBotUserId: Int64? = nil,
    bindsAgent: Bool = false
  ) {
    dependencies.nav3ChatOpenPreloader?.cancelPendingOpen()
    ToastCenter.shared.showLoading("Creating thread")
    Task {
      do {
        let result = try await dependencies.realtimeV2.send(CreateSubthreadTransaction(
          parentChatId: parentChatId,
          parentMessageId: nil,
          participants: agentBotUserId.map { [$0] } ?? [],
          agentContext: bindsAgent
            ? agentBotUserId.map { botUserId in
              InlineProtocol.AgentThreadContext.with { $0.botUserID = botUserId }
            }
            : nil
        ))
        guard case let .createSubthread(response) = result, response.hasChat else {
          throw LocalThreadCommandError.invalidCreateResponse
        }
        let peer: InlineKit.Peer = .thread(id: response.chat.id)
        await MainActor.run {
          ToastCenter.shared.dismiss()
          SidebarCleanup.shared.markOpened(peer)
          dependencies.requestOpenChat(peer: peer)
        }
        // The server keeps a nested thread without an anchor message out of
        // the chat list until it has activity. This one was asked for, so
        // follow it and show it under its parent, as the /thread command does.
        // Each step waits for the server: each result rewrites the local
        // dialog, and updateDialogOpen doesn't unhide, so an open result that
        // lands after showInChatList's would hide the new row again.
        let sidebarTransactions: [any Transaction2] = [
          UpdateDialogFollowModeTransaction(peerId: peer, selection: .following),
          ShowInChatListTransaction(peerId: peer),
          UpdateDialogOpenTransaction(peerId: peer, open: true),
        ]
        for transaction in sidebarTransactions {
          do {
            _ = try await dependencies.realtimeV2.send(transaction)
          } catch {
            Log.scoped("NewThreadAction").error("Could not show the new thread in the sidebar", error: error)
          }
        }
      } catch {
        await MainActor.run {
          ToastCenter.shared.dismiss()
          ToastCenter.shared.showError("Failed to create thread.")
        }
      }
    }
  }
}
