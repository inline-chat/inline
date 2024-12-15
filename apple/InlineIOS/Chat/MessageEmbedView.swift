import GRDB
import InlineKit
import SwiftUI

struct MessageEmbedView: View {
  var repliedToMessageId: Int64

  @Environment(\.appDatabase) var db
  @State private var repliedToMessage: FullMessage?

  init(repliedToMessageId: Int64) {
    self.repliedToMessageId = repliedToMessageId
  }

  var body: some View {
    VStack {
      Text(repliedToMessage?.user?.firstName ?? "")
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(repliedToMessage?.message.text ?? "")
        .font(.callout)
        .lineLimit(2)
        .foregroundStyle(.secondary)
    }
    .frame(height: 38)
    .background(ColorManager.shared.swiftUIColor.opacity(0.2))
    .onAppear {
      fetchRepliedMessage()
    }
    .onChange(of: repliedToMessageId) {
      fetchRepliedMessage()
    }
  }

  private func fetchRepliedMessage() {
    print("Fetching replied message: \(repliedToMessageId)")
    Task {
      do {
        let message = try await db.dbWriter.read { db in
          try Message
            .filter(Column("messageId") == repliedToMessageId)
            .including(optional: Message.from)
            .asRequest(of: FullMessage.self)
            .fetchOne(db)
        }
        await MainActor.run {
          self.repliedToMessage = message
          print("Fetched message: \(String(describing: message))")
        }
      } catch {
        Log.shared.error("Failed to fetch replied message", error: error)
      }
    }
  }
}
