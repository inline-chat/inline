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
    VStack(alignment: .leading) {
      Text(repliedToMessage?.user?.firstName ?? "")
        .font(.caption)
        .foregroundStyle(repliedToMessage?.message.out == true ? .white : .secondary)
      Text(repliedToMessage?.message.text ?? "")
        .font(.callout)
        .lineLimit(2)
        .foregroundStyle(repliedToMessage?.message.out == true ? .white : .secondary)
    }

    .frame(height: 38)
    .padding(6)
    .background(.white.opacity(0.2))
    .cornerRadius(12)

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

#Preview {
  VStack(spacing: 20) {
    // Preview with full data
    MessageEmbedView(repliedToMessageId: 1)
      .previewsEnvironment(.populated)
      .padding()
  }
  .frame(width: 300, height: 300)
  .background(.red)
}
