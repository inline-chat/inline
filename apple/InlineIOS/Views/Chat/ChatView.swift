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
      if fullChatViewModel.fullMessages.count == 0 {
        VStack {
          Text("💬")
            .font(.largeTitle)
          Text("No messages yet")
            .font(.title3)
            .fontWeight(.medium)
        }
        .animation(.easeInOut(duration: 0.3), value: fullChatViewModel.fullMessages.isEmpty)

        .frame(maxHeight: .infinity)
      } else {
        chatMessages
      }
      inputArea
    }
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .principal) {
        chatHeader
      }
    }
    .toolbarRole(.editor)
    .toolbar(.hidden, for: .tabBar)
    .onTapGesture(perform: dismissKeyboard)
    .onAppear {
      fetchMessages()
    }
  }

  private func fetchMessages() {
    Task {
      try await dataManager.getChatHistory(
        peerUserId: nil,
        peerThreadId: nil,
        peerId: peer
      )
    }
  }
}

// MARK: - View Components

private extension ChatView {
  var chatMessages: some View {
    MessagesCollectionView(fullMessages: fullChatViewModel.fullMessages)
      .padding(.vertical, 8)
  }

  var chatHeader: some View {
    HStack(spacing: 2) {
      InitialsCircle(firstName: title, lastName: nil, size: 26)
        .padding(.trailing, 6)
      Text(title)
        .font(.title3)
        .fontWeight(.medium)
    }
  }

  var inputArea: some View {
    VStack(spacing: 0) {
      Divider()
        .ignoresSafeArea()
      HStack {
        messageTextField
        sendButton
      }
      .padding()
    }
    .background(.clear)
  }

  var messageTextField: some View {
    TextField("Type a message", text: $text, axis: .vertical)
      .textFieldStyle(.plain)
      .onSubmit(sendMessage)
  }

  var sendButton: some View {
    Button(action: sendMessage) {
      Image(systemName: "arrow.up")
        .foregroundColor(text.isEmpty ? .secondary : .blue)
        .font(.body)
    }
    .disabled(text.isEmpty)
  }
}

// MARK: - Actions

private extension ChatView {
  func dismissKeyboard() {
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
        if !text.isEmpty {
          let randomId = Int64.random(in: Int64.min ... Int64.max)

          try await dataManager.sendMessage(
            chatId: fullChatViewModel.chat?.id ?? 0,
            peerUserId: nil,
            peerThreadId: nil,
            text: text,
            peerId: peer,
            randomId: randomId
          )

          text = ""
        }
      } catch {
        Log.shared.error("Failed to send message", error: error)
      }
    }
  }
}

extension View {
  func flipped() -> some View {
    rotationEffect(.init(radians: .pi))
      .scaleEffect(x: -1, y: 1, anchor: .center)
  }
}
