import Combine
import InlineKit
import InlineUI
import SwiftUI

struct ChatView: View {
  // MARK: - Properties

  @EnvironmentStateObject var fullChatViewModel: FullChatViewModel
  @EnvironmentObject var nav: Navigation
  @EnvironmentObject var dataManager: DataManager
  @Environment(\.appDatabase) var database

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
      chatMessages

    }
    .safeAreaInset(edge: .bottom) {
      inputArea
    }
    .safeAreaInset(edge: .top) {
      if let user = fullChatViewModel.peerUser {
        ChatHeaderViewRepresentable(
          user: user,
          onBack: {
            nav.pop()
          }
        )
        .frame(height: 45)
        .background(Color.clear.edgesIgnoringSafeArea(.all))
      }
    }
    .navigationBarHidden(true)
    .onAppear {
      fetchMessages()
    }
  }

  // MARK: - View Components
  @ViewBuilder
  private var chatMessages: some View {
    MessagesCollectionView(fullMessages: fullChatViewModel.fullMessages)
  }

  @ViewBuilder
  private var inputArea: some View {
    HStack {
      ComposeView(messageText: $text)
      ZStack {
        sendButton
          .transition(.scale(scale: 0.8).combined(with: .opacity))
      }
      .animation(.easeInOut(duration: 0.1), value: text.isEmpty)

    }
    .animation(.easeInOut(duration: 0.1), value: text.isEmpty)
    .padding(.vertical, 6)
    .padding(.horizontal)
    .overlay(alignment: .top) {
      Divider()
        .padding(.top, -8)
    }
    .background(Color(.systemBackground))
  }

  @ViewBuilder
  var sendButton: some View {
    if !text.isEmpty {
      Button(action: sendMessage) {
        Image(systemName: "paperplane.fill")
          .foregroundStyle(.blue)
          .font(.system(size: 20, weight: .semibold))
          .frame(width: 30, height: 30)

      }
    }
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

  func sendMessage() {
    Task {
      do {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let chatId = fullChatViewModel.chat?.id else { return }

        let messageText = text
        text = ""

        // Add haptic feedback
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        let peerUserId: Int64? = if case .user(let id) = peer { id } else { nil }
        let peerThreadId: Int64? = if case .thread(let id) = peer { id } else { nil }

        let randomId = Int64.random(in: Int64.min...Int64.max)
        let message = Message(
          messageId: -randomId,
          randomId: randomId,
          fromId: Auth.shared.getCurrentUserId()!,
          date: Date(),
          text: messageText,
          peerUserId: peerUserId,
          peerThreadId: peerThreadId,
          chatId: chatId,
          out: true
        )

        try await database.dbWriter.write { db in
          try message.save(db)
        }

        try await dataManager.sendMessage(
          chatId: chatId,
          peerUserId: peerUserId,
          peerThreadId: peerThreadId,
          text: messageText,
          peerId: peer,
          randomId: randomId
        )
      } catch {
        Log.shared.error("Failed to send message", error: error)
        // Optionally show error to user
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
