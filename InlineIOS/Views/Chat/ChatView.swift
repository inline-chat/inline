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

  private var chatMessages: some View {
    MessagesCollectionView(fullMessages: fullChatViewModel.fullMessages)
  }

  private var inputArea: some View {
    HStack {
      ComposeView(messageText: $text)
      sendButton
    }
    .animation(.smoothSnappy, value: !text.isEmpty)
    .padding(.vertical, 6)
    .padding(.horizontal)
    .overlay(alignment: .top) {
      Divider()
        .padding(.top, -8)
    }
    .background(Color(.systemBackground))
  }

  var sendButton: some View {
    Group {
      if !text.isEmpty {
        Button(action: sendMessage) {
          Image(systemName: "paperplane.fill")
            .foregroundStyle(.blue)
            .font(.system(size: 20, weight: .semibold))
            .frame(width: 30, height: 30)

        }
        .transition(
          .asymmetric(
            insertion: .scale(scale: 0.6)
              .combined(with: .opacity)
              .combined(with: .offset(x: -10)),
            removal: .scale(scale: 0.6)
              .combined(with: .opacity)
              .combined(with: .offset(x: -10))
          )
        )
      } else {
        EmptyView()
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
    let messageToSend = text

    withAnimation(.punchySnappy) {
      text = ""
    }

    // Add haptic feedback
    let generator = UIImpactFeedbackGenerator(style: .medium)
    generator.impactOccurred()

    // Send message
    Task {
      do {
        let randomId = Int64.random(in: Int64.min...Int64.max)
        try await dataManager.sendMessage(
          chatId: fullChatViewModel.chat?.id ?? 0,
          peerUserId: nil,
          peerThreadId: nil,
          text: messageToSend,
          peerId: peer,
          randomId: randomId
        )
      } catch {
        withAnimation(.smoothSnappy) {
          text = messageToSend
        }
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
