import Combine
import GRDB
import InlineProtocol
import Logger
import SwiftUI

// View model that publishes all **documents** that were shared inside a chat.
//
// A *document* here refers to any `InlineProtocol.Document` (files, PDFs, etc.)
// that was attached to a message. We expose them as an array of `DocumentInfo`

// MARK: - DocumentMessage

/// Represents a document along with its associated message information
public struct DocumentMessage: Codable, Equatable, Hashable, FetchableRecord, PersistableRecord, Sendable,
  Identifiable
{
  public var id: Int64 {
    message.messageId
  }

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
      .filter(sql: "resourceFlags & ? != 0", arguments: [MessageHistoryScope.files.resourceMask.rawValue])
      .filter(Message.Columns.documentId != nil)
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
public final class ChatDocumentsViewModel: ChatResourceWindow<DocumentMessage>, @unchecked Sendable {
  public var documentMessages: [DocumentMessage] {
    rows
  }

  public var documents: [DocumentInfo] {
    rows.map(\.document)
  }

  public init(db: AppDatabase, chatId: Int64, peer: Peer) {
    super.init(
      db: db,
      chatId: chatId,
      peer: peer,
      scope: .files,
      fetchRows: { db, limit in
        try DocumentMessage.queryRequest()
          .filter(Message.Columns.chatId == chatId)
          .order(Message.Columns.messageId.desc)
          .limit(limit)
          .fetchAll(db)
      },
      messageID: { $0.message.messageId }
    )
  }

  public var groupedDocuments: [DocumentGroup] {
    groupedDocumentMessages.map { DocumentGroup(date: $0.date, documents: $0.messages.map(\.document)) }
  }

  @Published public private(set) var groupedDocumentMessages: [DocumentMessageGroup] = []

  override public func rowsDidChange() {
    groupedDocumentMessages = Dictionary(grouping: rows) { Calendar.current.startOfDay(for: $0.message.date) }
      .map { DocumentMessageGroup(date: $0.key, messages: $0.value.sorted { lhs, rhs in
        if lhs.message.date != rhs.message.date {
          return lhs.message.date > rhs.message.date
        }
        return lhs.message.messageId > rhs.message.messageId
      }) }
      .sorted { $0.date > $1.date }
  }

  public func documentMessage(for documentId: Int64) -> DocumentMessage? {
    rows.first { $0.document.id == documentId }
  }

  public func documentMessages(from senderId: Int64) -> [DocumentMessage] {
    rows.filter { $0.message.fromId == senderId }
  }
}

/// Helper struct for grouped documents
public struct DocumentGroup {
  public let date: Date
  public let documents: [DocumentInfo]
}

/// Helper struct for grouped document messages
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
