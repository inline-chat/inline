import InlineKit
import SwiftUI

struct MessageView: View {
  let message: Message
  @Environment(\.appDatabase) var database: AppDatabase

  init(message: Message) {
    self.message = message
  }

  var body: some View {
    Text(message.text ?? "")
      .padding(10)
      .font(.body)
      .foregroundColor(.primary)
      .frame(minWidth: 40, alignment: .leading)
      .background(Color(.systemGray6).opacity(0.7))
      .cornerRadius(16)
      .id(message.id)
      .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 16))
      .contextMenu {
        Button("Copy") {
          UIPasteboard.general.string = message.text ?? ""
        }
        Button("Delete", role: .destructive) {
          Task {
            do {
              _ = try await database.dbWriter.write { db in
                try Message.deleteOne(db, id: message.id)
              }
            } catch {
              Log.shared.error("Failed to delete message", error: error)
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

#Preview("Message Preview Group") {
  VStack(alignment: .leading, spacing: 12) {
    // DM from Alice
    MessageView(
      message: Message(
        messageId: 2,
        fromId: 2, // Alice's ID
        date: Date().addingTimeInterval(-3500),
        text: "Hi there! How are you?",
        peerUserId: 2,
        peerThreadId: nil,
        chatId: 1
      )
    )

    // Reply from current user
    MessageView(
      message: Message(
        messageId: 3,
        fromId: 1, // Current user's ID
        date: Date().addingTimeInterval(-3400),
        text: "I'm good! Just checking out the new chat app.",
        peerUserId: 2,
        peerThreadId: nil,
        chatId: 1,
        out: true
      )
    )

    // Thread message from Bob
    MessageView(
      message: Message(
        messageId: 3,
        fromId: 3, // Bob's ID
        date: Date().addingTimeInterval(-7000),
        text: "Let's build something awesome!",
        peerUserId: nil,
        peerThreadId: 3,
        chatId: 3
      )
    )
  }
  .padding()
  .previewsEnvironment(.populated)
  .frame(maxWidth: 400)
}
