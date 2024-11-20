import SwiftUI
import InlineKit

struct Compose: View {
  var chatId: Int64?
  var peerId: Peer
  // Used for optimistic UI
  var topMsgId: Int64?

  @EnvironmentObject var data: DataManager
  @EnvironmentObject var scroller: ChatScroller
  @EnvironmentObject var focus: ChatFocus
  @Environment(\.appDatabase) var db
  @State private var text: String = ""

  var body: some View {
    HStack {
      TextField("Type a message", text: $text)
        .textFieldStyle(.roundedBorder)
        .padding(.horizontal, 8)
        .bindChatViewFocus(to: focus, field: .compose)
        .submitLabel(.send)
        .onSubmit {
          send()
        }

      Button {
        send()

      } label: {
        Image(systemName: "paperplane")
          .resizable()
          .scaledToFit()
          .frame(width: 20, height: 20)
          .padding(8)
          .background(Color.accentColor)
          .clipShape(Circle())
      }
      .buttonStyle(.plain)
    }
    .background(.regularMaterial)
  }

  private func send() {
    Task {
      do {
        // Checks
        if text.isEmpty {
          return
        }
        guard let chatId = chatId else { return }

        // Clear input
        let _text = text
        text = ""

        let peerUserId: Int64? = if case .user(let id) = peerId { id } else { nil }
        let peerThreadId: Int64? = if case .thread(let id) = peerId { id } else { nil }

        let randomId = Int64.random(in: Int64.min ... Int64.max)
        // Optimistic UI
        let message = Message(
          messageId: -randomId,
          randomId: randomId,
          fromId: Auth.shared.getCurrentUserId()!,
          date: Date(),
          text: _text,
          peerUserId: peerUserId,
          peerThreadId: peerThreadId,
          chatId: chatId
        )

        try await db.dbWriter.write { db in
          print("optimistic message: \(message)")
          try message.save(db)
        }

        // Animate to bottom
        scroller.scrollToBottom(animate: true)

        // Send message
        try await data
          .sendMessage(
            chatId: chatId,
            peerUserId: nil,
            peerThreadId: nil,
            text: _text,
            peerId: self.peerId,
            randomId: randomId
          )

      } catch {
        Log.shared.error("Failed to send message", error: error)
      }
    }
  }
}
