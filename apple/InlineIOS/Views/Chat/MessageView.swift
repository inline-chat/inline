import GRDB
import InlineKit
import SwiftUI

struct MessageView: View {
  // MARK: - Properties

  let fullMessage: FullMessage
  @Environment(\.appDatabase) var database: AppDatabase

  // MARK: - Initialization

  init(fullMessage: FullMessage) {
    self.fullMessage = fullMessage
  }

  var alignment: Alignment {
    fullMessage.message.out == true ? .trailing : .leading
  }

  var out: Bool {
    fullMessage.message.out == true
  }

  private var formattedDate: String {
    let formatter = DateFormatter()
    if Calendar.current.isDateInToday(fullMessage.message.date) {
      formatter.dateFormat = "HH:mm"
    } else {
      formatter.dateFormat = "MMM d"
    }
    return formatter.string(from: fullMessage.message.date)
  }

  // MARK: - Body

  var body: some View {
    HStack {
      if fullMessage.message.out == true {
        Spacer()
      }

      messageBubble

      if fullMessage.message.out != true {
        Spacer()
      }
    }
  }
}

// MARK: - Components

extension MessageView {
  fileprivate var messageBubble: some View {
    //    VStack(alignment: alignment == .leading ? .leading : .trailing, spacing: 2) {
    //      userNameText
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .bottom, spacing: 0) {
        Text(fullMessage.message.text ?? "")
          .font(.body)
          .foregroundColor(out ? .white : .primary)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
          .lineLimit(nil)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(out ? .blue : Color(.systemGray6).opacity(0.7))
    .cornerRadius(18)
    .id(fullMessage.message.id)
    .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 18))
    .contextMenu { contextMenuButtons }
    .frame(maxWidth: UIScreen.main.bounds.width * 0.75, alignment: alignment)
    //    }
  }

  fileprivate var userNameText: some View {
    Text(fullMessage.user?.fullName ?? "")
      .font(.subheadline)
      .foregroundColor(.secondary)
      .fontWeight(.medium)
  }

  fileprivate var contextMenuButtons: some View {
    Group {
      Button("Copy") {
        UIPasteboard.general.string = fullMessage.message.text ?? ""
      }
    }
  }
}

// MARK: - Actions

extension MessageView {
  fileprivate func deleteMessage() async {
    do {
      _ = try await database.dbWriter.write { db in
        try Message.deleteOne(db, id: fullMessage.message.id)
      }
    } catch {
      Log.shared.error("Failed to delete message", error: error)
    }
  }
}

// MARK: - Preview

//
// #Preview("Message Preview Group") {
//  VStack(alignment: .leading, spacing: 12) {
//    // DM from Alice
//    MessageView(
//      fullMessage: Message(
//        messageId: 2,
//        fromId: 2, // Alice's ID
//        date: Date().addingTimeInterval(-3500),
//        text: "Hi there! How are you?",
//        peerUserId: 2,
//        peerThreadId: nil,
//        chatId: 1
//      )
//    )
//
//    // Reply from current user
//    MessageView(
//      fullMessage: Message(
//        messageId: 3,
//        fromId: 1, // Current user's ID
//        date: Date().addingTimeInterval(-3400),
//        text: "I'm good! Just checking out the new chat app.",
//        peerUserId: 2,
//        peerThreadId: nil,
//        chatId: 1,
//        out: true
//      )
//    )
//
//    // Thread message from Bob
//    MessageView(
//      fullMessage: Message(
//        messageId: 4,
//        fromId: 3, // Bob's ID
//        date: Date().addingTimeInterval(-7000),
//        text: "Let's build something awesome!",
//        peerUserId: nil,
//        peerThreadId: 3,
//        chatId: 3
//      )
//    )
//  }
//  .padding()
//  .previewsEnvironment(.populated)
//  .frame(maxWidth: 400)
// }
