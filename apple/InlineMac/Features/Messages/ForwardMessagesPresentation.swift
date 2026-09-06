import AppKit
import InlineKit
import InlineUI
import Logger
import Observation
import SwiftUI

@MainActor
@Observable
final class ForwardMessagesPresenter {
  var request: ForwardMessagesRequest?
  private(set) var recentDestinations: [HomeChatListItemSnapshot] = []
  private(set) var hasLoadedRecentDestinations = false

  func observeRecentDestinations(using catalog: CommandBarCatalogService) async {
    defer {
      recentDestinations = []
      hasLoadedRecentDestinations = false
    }
    for await _ in await catalog.invalidations() {
      guard !Task.isCancelled else { return }
      _ = await catalog.start()
      let destinations = await catalog.recentForwardDestinations()
      guard !Task.isCancelled else { return }
      recentDestinations = destinations
      hasLoadedRecentDestinations = true
    }
  }

  func sendImmediately(messages: [FullMessage], to destination: HomeChatListItemSnapshot, dependencies: AppDependencies) {
    guard let source = messages.first,
          messages.allSatisfy({
            $0.chatId == source.chatId && $0.message.messageId > 0 && !$0.message.isServiceMessage
              && !$0.message.isSubthreadPlacement && ($0.message.status == nil || $0.message.status == .sent)
          }) else {
      ToastCenter.shared.showError("These messages cannot be forwarded.")
      return
    }
    Task { @MainActor in
      do {
        let result = try await dependencies.realtimeV2.send(.forwardMessages(
          fromPeerId: source.peerId,
          toPeerId: destination.peerId,
          messageIds: messages.map(\.message.messageId)
        ))
        if case let .forwardMessages(response) = result, response.updates.isEmpty {
          _ = await dependencies.realtimeV2.sendQueued(.getChatHistory(peer: destination.peerId))
        }
        ToastCenter.shared.showSuccess("Forwarded to \(destination.title)")
      } catch {
        ToastCenter.shared.showError(
          "Could not confirm forwarding. Messages may already have arrived. Check before retrying. \(error.localizedDescription)"
        )
      }
    }
  }

  func present(messages: [FullMessage], onComplete: (() -> Void)? = nil) {
    guard !messages.isEmpty else { return }
    request = ForwardMessagesRequest(messages: messages, onComplete: onComplete)
  }

  func dismiss() {
    request = nil
  }
}

struct ForwardMessagesRequest: Identifiable {
  let id = UUID()
  let messages: [FullMessage]
  let onComplete: (() -> Void)?
}

struct ForwardMessagesPresentation: ViewModifier {
  let dependencies: AppDependencies?

  func body(content: Content) -> some View {
    if let dependencies, let presenter = dependencies.forwardMessages {
      content.sheet(item: Binding(
        get: { presenter.request },
        set: { presenter.request = $0 }
      )) { request in
        if ExperimentalFeatureFlags.quickForwardEnabled {
          QuickForwardMessagesSheet(
            messages: request.messages,
            database: dependencies.database,
            sendComment: { destination, comment in
              guard let chatId = destination.dialog.chatId ?? destination.chat?.id else {
                throw QuickForwardError.missingChat
              }
              _ = try await dependencies.realtimeV2.send(.sendMessage(
                text: comment,
                peerId: destination.peerId,
                chatId: chatId
              ))
            },
            forward: { destination, selection in
              let result = try await dependencies.realtimeV2.send(.forwardMessages(
                fromPeerId: selection.fromPeerId,
                toPeerId: destination.peerId,
                messageIds: selection.messageIds
              ))
              if case let .forwardMessages(response) = result, response.updates.isEmpty {
                _ = await dependencies.realtimeV2.sendQueued(.getChatHistory(peer: destination.peerId))
              }
            },
            onComplete: { count in
              request.onComplete?()
              ToastCenter.shared.showSuccess(count == 1 ? "Forwarded" : "Forwarded to \(count) chats")
            }
          )
          .accentColor(Color(nsColor: Theme.accentColor))
        } else {
          ForwardMessagesSheet(
            messages: request.messages,
            database: dependencies.database,
            onSelect: { destination, selection in
              openForwardDestination(destination, selection: selection, dependencies: dependencies)
            },
            onSend: { destinations, selection in
              await sendForwardMessages(destinations: destinations, selection: selection)
            }
          )
          .frame(width: 480, height: 560)
        }
      }
    } else {
      content
    }
  }

  private func openForwardDestination(
    _ destination: HomeChatItem,
    selection: ForwardMessagesSheet.ForwardMessagesSelection,
    dependencies: AppDependencies
  ) {
    guard let destinationChatId = destination.dialog.chatId ?? destination.chat?.id else {
      Log.shared.error("Forward nav failed: missing destination chat id")
      return
    }

    let destinationPeer = destination.peerId
    let state = ChatsManager.get(for: destinationPeer, chatId: destinationChatId)
    state.setForwardingMessages(
      fromPeerId: selection.fromPeerId,
      sourceChatId: selection.sourceChatId,
      messageIds: selection.messageIds
    )

    dependencies.requestOpenChat(peer: destinationPeer)
    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
  }

  @MainActor
  private func sendForwardMessages(
    destinations: [HomeChatItem],
    selection: ForwardMessagesSheet.ForwardMessagesSelection
  ) async {
    guard !destinations.isEmpty else { return }
    guard !selection.messageIds.isEmpty else {
      Log.shared.error("Forward failed: empty message ids")
      return
    }

    for destination in destinations {
      let destinationPeer = destination.peerId
      do {
        let result = try await Api.realtime.send(.forwardMessages(
          fromPeerId: selection.fromPeerId,
          toPeerId: destinationPeer,
          messageIds: selection.messageIds
        ))

        if case let .forwardMessages(response) = result, response.updates.isEmpty {
          _ = await Api.realtime.sendQueued(.getChatHistory(peer: destinationPeer))
        }
      } catch {
        Log.shared.error("Forward failed", error: error)
      }
    }

    ToastCenter.shared.showSuccess("Forwarded to \(destinations.count) chats")
  }
}

private enum QuickForwardError: LocalizedError {
  case missingChat

  var errorDescription: String? {
    "This chat is no longer available. Close the picker and choose another chat."
  }
}
