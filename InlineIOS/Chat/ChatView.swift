import Combine
import InlineKit
import InlineUI
import SwiftUI

struct ChatView: View {
  var peer: Peer

  @State var text: String = ""

  @EnvironmentStateObject var fullChatViewModel: FullChatViewModel
  @EnvironmentObject var nav: Navigation
  @EnvironmentObject var dataManager: DataManager
  @Environment(\.appDatabase) var database
  @Environment(\.scenePhase) var scenePhase

  init(peer: Peer) {
    self.peer = peer
    _fullChatViewModel = EnvironmentStateObject { env in
      FullChatViewModel(db: env.appDatabase, peer: peer, limit: 80)
    }
  }

  // MARK: - Body

  var body: some View {
    VStack(spacing: 0) {
      MessagesCollectionView(fullMessages: fullChatViewModel.fullMessages.reversed())
        .safeAreaInset(edge: .bottom) {
          HStack {
            ComposeView(messageText: $text)

            sendButton
          }
          .padding(.vertical, 6)
          .padding(.horizontal)
          .background(Color(uiColor: .systemBackground))
        }
    }
    .toolbar {
      ToolbarItem(placement: .principal) {
        Text(title)
          .font(.body)
          .fontWeight(.semibold)
        // TODO: Add status
      }

      #if DEBUG
      ToolbarItem(placement: .topBarTrailing) {
        Button("Debug") {
          sendDebugMessages()
        }
      }
      #endif
    }
    .navigationBarHidden(false)
    .toolbarRole(.editor)
    .toolbarBackground(.visible, for: .navigationBar)
    .toolbarTitleDisplayMode(.inline)
    .onAppear {
      fetchMessages()
    }
    .onChange(of: scenePhase) { _, newPhase in
      if newPhase == .active {
        fetchMessages()
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

// MARK: - Helper Methods

extension ChatView {
  private func fetchMessages() {
    Task {
      do {
        try await dataManager.getChatHistory(
          peerUserId: nil,
          peerThreadId: nil,
          peerId: peer
        )
      } catch {
        Log.shared.error("Failed to fetch messages", error: error)
      }
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

        // Add haptic feedback
        let generator = UIImpactFeedbackGenerator(style: .soft)
        generator.impactOccurred()

        // Delay clearing the text field to allow animation to complete
        withAnimation {
          text = ""
        }

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
          out: true,
          status: .sending,
          repliedToMessageId: ChatState.shared.getState(chatId: chatId).replyingMessageId
        )

        // Save message to database
        try await database.dbWriter.write { db in
          try message.save(db)
        }

        // Send message to server
        try await dataManager.sendMessage(
          chatId: chatId,
          peerUserId: peerUserId,
          peerThreadId: peerThreadId,
          text: messageText,
          peerId: peer,
          randomId: randomId,
          repliedToMessageId: ChatState.shared.getState(chatId: chatId).replyingMessageId
        )
      } catch {
        Log.shared.error("Failed to send message", error: error)
        // Optionally show error to user
      }
    }
  }

  private func sendDebugMessages() {
    Task {
      guard let chatId = fullChatViewModel.chat?.id else { return }

      // Send 80 messages with different lengths
      for i in 1...200 {
        let messageLength = Int.random(in: 10...200)
        let messageText = String(repeating: "Test message \(i) ", count: messageLength / 10)

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
          out: true,
          status: .sending,
          repliedToMessageId: nil
        )

        do {
          // Save to database
          try await database.dbWriter.write { db in
            try message.save(db)
          }

          // Send to server
          try await dataManager.sendMessage(
            chatId: chatId,
            peerUserId: peerUserId,
            peerThreadId: peerThreadId,
            text: messageText,
            peerId: peer,
            randomId: randomId,
            repliedToMessageId: nil
          )

          // Add small delay between messages
          try await Task.sleep(nanoseconds: 100_000_000) // 0.1 second
        } catch {
          Log.shared.error("Failed to send debug message", error: error)
        }
      }
    }
  }
}

// MARK: - Helper Properties

extension ChatView {
  var title: String {
    if case .user = peer {
      return fullChatViewModel.peerUser?.firstName ?? ""
    } else {
      return fullChatViewModel.chat?.title ?? ""
    }
  }
}

// MARK: - Views

extension ChatView {
  @ViewBuilder
  private var chatMessages: some View {
    MessagesCollectionView(fullMessages: fullChatViewModel.fullMessages)
  }

  @ViewBuilder
  private var inputArea: some View {
    HStack {
      ComposeView(messageText: $text)

      sendButton
    }
    .padding(.vertical, 6)
    .padding(.horizontal)
    .background(Color(uiColor: .systemBackground))
    .animation(nil, value: text)
  }

  @ViewBuilder
  var sendButton: some View {
    if !text.isEmpty {
      Button {
        sendMessage()
      } label: {
        Image(systemName: "paperplane.fill")
          .resizable()
          .scaledToFit()
          .foregroundStyle(.white)
      }
      .buttonStyle(
        CircleButtonStyle(
          size: 30,
          backgroundColor: .accentColor
        )
      )
      .transition(
        .asymmetric(
          insertion: .scale.combined(with: .opacity)
            .animation(
              .spring(
                response: 0.35,
                dampingFraction: 0.5,
                blendDuration: 0
              )
            ),
          removal: .scale.combined(with: .opacity)
            .animation(
              .spring(
                response: 0.25,
                dampingFraction: 0.5,
                blendDuration: 0
              )
            )
        )
      )
    }
  }
}

struct CircleButtonStyle: ButtonStyle {
  let size: CGFloat
  let backgroundColor: Color

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .padding(8)
      .frame(width: size, height: size)
      .background(
        Circle()
          .fill(backgroundColor)
      )
      .scaleEffect(configuration.isPressed ? 0.85 : 1.0)
      .animation(
        .spring(
          response: 0.2,
          dampingFraction: 0.5,
          blendDuration: 0
        ),
        value: configuration.isPressed
      )
  }
}
