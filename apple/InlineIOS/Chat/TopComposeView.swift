import GRDB
import InlineKit
import SwiftUI

struct TopComposeView: View {
  var replyingMessageId: Int64
  var chatId: Int64
  @Environment(\.appDatabase) var db
  @State private var repliedMessage: FullMessage?

  init(replyingMessageId: Int64, chatId: Int64) {
    self.replyingMessageId = replyingMessageId
    self.chatId = chatId
    print("TopComposeView init with id: \(replyingMessageId)")
  }

  var body: some View {
    ZStack {
      if let message = repliedMessage {
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text(message.user?.fullName ?? "Deleted User")
              .font(.callout)
              .foregroundStyle(.tertiary)
              .fontWeight(.medium)

            Spacer()

            Button {
              ChatState.shared.clearReplyingMessageId(chatId: chatId)
            } label: {
              Image(systemName: "xmark")
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
          }

          Text(
            (message.message.text ?? "")
              .replacingOccurrences(of: "\r\n", with: " ")
              .replacingOccurrences(of: "\n", with: " ")
          )
          .font(.callout)
          .lineLimit(2)
          .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .frame(maxWidth: .infinity)
        .frame(height: 58)
        .background(.clear)
        .overlay(alignment: .top) {
          Divider()
        }
        .overlay(alignment: .bottom) {
          Divider()
        }
      }
    }
    .onAppear {
      fetchRepliedMessage()
    }
    .onChange(of: replyingMessageId) {
      fetchRepliedMessage()
    }
  }

  private func fetchRepliedMessage() {
    print("Fetching replied message: \(replyingMessageId)")
    Task {
      do {
        let message = try await db.dbWriter.read { db in
          try Message
            .filter(Column("messageId") == replyingMessageId)
            .including(optional: Message.from)
            .asRequest(of: FullMessage.self)
            .fetchOne(db)
        }
        await MainActor.run {
          self.repliedMessage = message
        }
      } catch {
        Log.shared.error("Failed to fetch replied message", error: error)
      }
    }
  }
}
