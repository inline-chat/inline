import Combine
import GRDB
import Logger
import SwiftUI

/// View model that publishes all **documents** that were shared inside a chat.
///
/// A *document* here refers to any `InlineProtocol.Document` (files, PDFs, etc.)
/// that was attached to a message. We expose them as an array of `DocumentInfo`

// MARK: - DocumentMessage

/// Represents a document along with its associated message information
public struct DocumentMessage: Codable, Equatable, Hashable, FetchableRecord, PersistableRecord, Sendable,
  Identifiable
{
  public var id: Int64 { document.id }
  public var message: Message
  public var document: DocumentInfo

  public enum CodingKeys: String, CodingKey {
    case message
    case document
  }

  public init(message: Message, document: DocumentInfo) {
    self.message = message
    self.document = document
  }

  /// Query request for fetching document messages with all related data
  public static func queryRequest() -> QueryInterfaceRequest<DocumentMessage> {
    Message
      .filter(Column("documentId") != nil)
      // Include document info with thumbnail
      .including(
        optional: Message.document.forKey(CodingKeys.document)
          .including(
            optional: Document.thumbnail
              .including(all: Photo.sizes.forKey(PhotoInfo.CodingKeys.sizes))
              .forKey(DocumentInfo.CodingKeys.thumbnail)
          )
      )
      .asRequest(of: DocumentMessage.self)
  }
}

@MainActor
public final class ChatDocumentsViewModel: ObservableObject, @unchecked Sendable {
  private let chatId: Int64
  private let db: AppDatabase

  @Published public private(set) var documents: [DocumentInfo] = []
  @Published public private(set) var documentMessages: [DocumentMessage] = []

  private var cancellable: AnyCancellable?
  private var messagesCancellable: AnyCancellable?

  // MARK: – Initialization

  public init(db: AppDatabase, chatId: Int64) {
    self.db = db
    self.chatId = chatId
    fetchDocuments()
    fetchDocumentMessages()
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

  private func fetchDocumentMessages() {
    messagesCancellable = ValueObservation
      .tracking { [chatId] db in
        try DocumentMessage.queryRequest()
          .filter(Column("chatId") == chatId)
          .order(Column("date").desc)
          .fetchAll(db)
      }
      .publisher(in: db.dbWriter, scheduling: .immediate)
      .sink(
        receiveCompletion: { Log.shared.error("Failed to load document messages \($0)") },
        receiveValue: { [weak self] messages in
          // Remove duplicates (same underlying document) while keeping order
          var seen: Set<Int64> = []
          let unique = messages.filter { message in
            let insert = seen.insert(message.document.id)
            return insert.inserted
          }
          self?.documentMessages = unique
        }
      )
  }

  // MARK: - Helper Methods

  // Group documents by date
  public var groupedDocuments: [DocumentGroup] {
    let calendar = Calendar.current
    let grouped = Dictionary(grouping: documents) { document in
      calendar.startOfDay(for: document.document.date)
    }

    return grouped.map { date, documents in
      DocumentGroup(date: date, documents: documents.sorted { $0.document.date > $1.document.date })
    }.sorted { $0.date > $1.date }
  }

  // Group document messages by date
  public var groupedDocumentMessages: [DocumentMessageGroup] {
    let calendar = Calendar.current
    let grouped = Dictionary(grouping: documentMessages) { documentMessage in
      calendar.startOfDay(for: documentMessage.message.date)
    }

    return grouped.map { date, messages in
      DocumentMessageGroup(date: date, messages: messages.sorted { $0.message.date > $1.message.date })
    }.sorted { $0.date > $1.date }
  }

  /// Get document message for a specific document ID
  public func documentMessage(for documentId: Int64) -> DocumentMessage? {
    documentMessages.first { $0.document.id == documentId }
  }

  /// Get all document messages from a specific sender
  public func documentMessages(from senderId: Int64) -> [DocumentMessage] {
    documentMessages.filter { $0.message.fromId == senderId }
  }
}

// Helper struct for grouped documents
public struct DocumentGroup {
  public let date: Date
  public let documents: [DocumentInfo]
}

// Helper struct for grouped document messages
public struct DocumentMessageGroup {
  public let date: Date
  public let messages: [DocumentMessage]
}

// MARK: - DocumentMessage Extensions

public extension DocumentMessage {
  var isOutgoing: Bool {
    message.out ?? false
  }

  var displayFileName: String {
    document.document.fileName ?? "Document"
  }

  var formattedFileSize: String? {
    guard let size = document.document.size else { return nil }

    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: Int64(size))
  }

  var hasThumbnail: Bool {
    document.thumbnail != nil
  }

  var mimeType: String? {
    document.document.mimeType
  }

  var isImage: Bool {
    guard let mimeType else { return false }
    return mimeType.hasPrefix("image/")
  }

  var isPDF: Bool {
    mimeType == "application/pdf"
  }

  var isDownloaded: Bool {
    document.document.localPath != nil
  }

  var localPath: String? {
    document.document.localPath
  }

  var downloadURL: String? {
    document.document.cdnUrl
  }
}

// MARK: - ChatDocumentsViewModel Extensions

public extension ChatDocumentsViewModel {
  /// Get all document messages of a specific MIME type
  func documentMessages(withMimeType mimeType: String) -> [DocumentMessage] {
    documentMessages.filter { $0.document.document.mimeType == mimeType }
  }

  /// Get all image documents
  var imageDocuments: [DocumentMessage] {
    documentMessages.filter(\.isImage)
  }

  /// Get all PDF documents
  var pdfDocuments: [DocumentMessage] {
    documentMessages.filter(\.isPDF)
  }

  /// Get all downloaded documents
  var downloadedDocuments: [DocumentMessage] {
    documentMessages.filter(\.isDownloaded)
  }

  /// Search document messages by file name
  func searchDocumentMessages(query: String) -> [DocumentMessage] {
    let lowercaseQuery = query.lowercased()
    return documentMessages.filter { documentMessage in
      let fileName = documentMessage.document.document.fileName?.lowercased() ?? ""
      let messageText = documentMessage.message.text?.lowercased() ?? ""
      return fileName.contains(lowercaseQuery) || messageText.contains(lowercaseQuery)
    }
  }

  /// Get document messages within a date range
  func documentMessages(from startDate: Date, to endDate: Date) -> [DocumentMessage] {
    documentMessages.filter { documentMessage in
      let messageDate = documentMessage.message.date
      return messageDate >= startDate && messageDate <= endDate
    }
  }

  /// Get the total size of all documents in bytes
  var totalDocumentsSize: Int {
    documentMessages.compactMap(\.document.document.size).reduce(0, +)
  }

  /// Get the formatted total size of all documents
  var formattedTotalSize: String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: Int64(totalDocumentsSize))
  }
}
