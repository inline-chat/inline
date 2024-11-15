import GRDB
import InlineKit
import SwiftUI

struct MessageView: View {
  // MARK: - Properties

  let message: Message
  @Environment(\.appDatabase) var database: AppDatabase
  @EnvironmentStateObject var fullMessage: FullMessageViewModel

  // MARK: - Initialization

  init(message: Message) {
    self.message = message
    _fullMessage = EnvironmentStateObject { env in
      FullMessageViewModel(db: env.appDatabase, messageId: message.id)
    }
  }

  var alignment: Alignment {
    message.out == true ? .trailing : .leading
  }

  // MARK: - Body

  var body: some View {
    HStack {
      if message.out == true {
        Spacer()
      }

      messageBubble

      if message.out != true {
        Spacer()
      }
    }
    .frame(maxWidth: .infinity, minHeight: 66, alignment: alignment)
  }
}

// MARK: - Components

private extension MessageView {
  var messageBubble: some View {
    VStack(alignment: .leading) {
      userNameText
      messageText
    }

    .padding(10)
    .background(Color(.systemGray6).opacity(0.7))
    .id(message.id)
    .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 16))
    .cornerRadius(16)
    .contextMenu { contextMenuButtons }
    .frame(maxWidth: UIScreen.main.bounds.width * 0.75, alignment: alignment)
  }

  var userNameText: some View {
    Text(fullMessage.fullMessage?.user?.fullName ?? "")
      .font(.subheadline)
      .foregroundColor(.secondary)
      .fontWeight(.medium)
  }

  var messageText: some View {
    Text(fullMessage.fullMessage?.message.text ?? "")
      .font(.body)
      .foregroundColor(.primary)
  }

  var contextMenuButtons: some View {
    Group {
      Button("Copy") {
        UIPasteboard.general.string = message.text ?? ""
      }
    }
  }
}

// MARK: - Actions

private extension MessageView {
  func deleteMessage() async {
    do {
      _ = try await database.dbWriter.write { db in
        try Message.deleteOne(db, id: message.id)
      }
    } catch {
      Log.shared.error("Failed to delete message", error: error)
    }
  }
}

// MARK: - Preview

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
