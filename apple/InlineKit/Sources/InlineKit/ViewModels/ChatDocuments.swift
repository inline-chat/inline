import Combine
import GRDB
import Logger
import SwiftUI

/// View model that publishes all **documents** that were shared inside a chat.
///
/// A *document* here refers to any `InlineProtocol.Document` (files, PDFs, etc.)
/// that was attached to a message. We expose them as an array of `DocumentInfo`

@MainActor
public final class ChatDocumentsViewModel: ObservableObject, @unchecked Sendable {
  private let chatId: Int64
  private let db: AppDatabase

  @Published public private(set) var documents: [DocumentInfo] = []

  private var cancellable: AnyCancellable?

  // MARK: – Initialization

  public init(db: AppDatabase, chatId: Int64) {
    self.db = db
    self.chatId = chatId
    fetchDocuments()
  }

  // MARK: – Private helpers

  private func fetchDocuments() {
    cancellable = ValueObservation
      .tracking { [chatId] db in
        // 1. Pick all messages from the chat that have an associated document.
        try Message
          .filter(Column("chatId") == chatId)
          .filter(Column("documentId") != nil)
          // 2. Bring the underlying `Document` (and its thumbnail) into the row
          //    so that GRDB can build a `DocumentInfo` value for us.
          .including(
            optional: Message.document
              .forKey(DocumentInfo.CodingKeys.document) // map to `document` property
              .including(
                optional: Document.thumbnail
                  .including(all: Photo.sizes.forKey(PhotoInfo.CodingKeys.sizes))
                  .forKey(DocumentInfo.CodingKeys.thumbnail) // map to `thumbnail` property
              )
          )
          // 3. We only care about the `DocumentInfo` portion of each row.
          .asRequest(of: DocumentInfo.self)
          .fetchAll(db)
      }
      .publisher(in: db.dbWriter, scheduling: .immediate)
      .sink(
        receiveCompletion: { Log.shared.error("Failed to load chat documents \($0)") },
        receiveValue: { [weak self] infos in
          // Remove duplicates (same underlying document) while keeping order
          var seen: Set<Int64> = []
          let unique = infos.filter { info in
            let insert = seen.insert(info.id)
            return insert.inserted
          }
          self?.documents = unique.sorted { $0.document.date > $1.document.date }
        }
      )
  }
}
