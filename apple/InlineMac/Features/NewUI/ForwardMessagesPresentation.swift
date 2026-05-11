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

  func present(messages: [FullMessage]) {
    guard !messages.isEmpty else { return }
    request = ForwardMessagesRequest(messages: messages)
  }

  func dismiss() {
    request = nil
  }
}

struct ForwardMessagesRequest: Identifiable {
  let id = UUID()
  let messages: [FullMessage]
}

struct ForwardMessagesPresentation: ViewModifier {
  let dependencies: AppDependencies?

  func body(content: Content) -> some View {
    if let dependencies, let presenter = dependencies.forwardMessages {
      content.sheet(item: Binding(
        get: { presenter.request },
        set: { presenter.request = $0 }
      )) { request in
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
