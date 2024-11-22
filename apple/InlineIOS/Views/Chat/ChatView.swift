import Combine
import InlineKit
import InlineUI
import SwiftUI

struct ChatView: View {
  // MARK: - Properties

  @EnvironmentStateObject var fullChatViewModel: FullChatViewModel
  @EnvironmentObject var nav: Navigation
  @EnvironmentObject var dataManager: DataManager

  var peer: Peer

  @State private var text: String = ""

  // MARK: - Initialization

  init(peer: Peer) {
    self.peer = peer
    _fullChatViewModel = EnvironmentStateObject { env in
      FullChatViewModel(db: env.appDatabase, peer: peer)
    }
  }

  var title: String {
    if case .user = peer {
      return fullChatViewModel.peerUser?.firstName ?? ""
    } else {
      return fullChatViewModel.chat?.title ?? ""
    }
  }

  // MARK: - Body

  var body: some View {
    VStack(spacing: 0) {
      if let user = fullChatViewModel.peerUser {
        ChatHeaderViewRepresentable(
          user: user,
          onBack: {
            nav.pop()
          }
        )
        .frame(height: 75)
      }

      chatMessages
      inputArea
    }
    .navigationBarHidden(true)
    .onAppear {
      fetchMessages()
    }

  }

  // MARK: - View Components

  private var chatMessages: some View {
    MessagesCollectionView(fullMessages: fullChatViewModel.fullMessages)
      .padding(.vertical, 8)
  }

  private var inputArea: some View {
    HStack {
      ComposeView(messageText: $text)
      sendButton
    }
    .padding(.vertical, 6)
    .padding(.horizontal)
    .overlay(alignment: .top) {
      Divider()
        .padding(.top, -8)
    }
  }

  private var sendButton: some View {
    Button(action: sendMessage) {
      Image(systemName: "paperplane.fill")
        .foregroundColor(text.isEmpty ? .secondary : .blue)
        .font(.system(size: 20, weight: .semibold))
        .contentTransition(.symbolEffect(.replace.offUp.byLayer))
        .scaleEffect(text.isEmpty ? 0.9 : 1.0)
        .rotationEffect(.degrees(text.isEmpty ? 0 : 45))
        .animation(.spring(response: 0.4, dampingFraction: 0.6), value: text.isEmpty)
    }
    .disabled(text.isEmpty)
  }

  // MARK: - Methods

  private func fetchMessages() {
    Task {
      try await dataManager.getChatHistory(
        peerUserId: nil,
        peerThreadId: nil,
        peerId: peer
      )
    }
  }

  private func dismissKeyboard() {
    UIApplication.shared.sendAction(
      #selector(UIResponder.resignFirstResponder),
      to: nil,
      from: nil,
      for: nil
    )
  }

  private func sendMessage() {
    Task {
      do {
        if !text.isEmpty {
          let randomId = Int64.random(in: Int64.min...Int64.max)

          try await dataManager.sendMessage(
            chatId: fullChatViewModel.chat?.id ?? 0,
            peerUserId: nil,
            peerThreadId: nil,
            text: text,
            peerId: peer,
            randomId: randomId
          )
        }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
          text = ""
        }
      } catch {
        Log.shared.error("Failed to send message", error: error)
      }
    }
  }
}

// MARK: - Helper Extensions

extension View {
  func flipped() -> some View {
    rotationEffect(.init(radians: .pi))
      .scaleEffect(x: -1, y: 1, anchor: .center)
  }
}
