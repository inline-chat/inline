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
      .frame(maxWidth: .infinity, alignment: .leading)
      .id(message.id)
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
  }
}

// #Preview {
//  MessageView(
//    message: Message(
//      id: 1,
//      fromId: 1,
//      date: Date(),
//      text: "Hello, world!",
//      peerUserId: 1,
//      peerThreadId: nil
//    )
//  )
// }
