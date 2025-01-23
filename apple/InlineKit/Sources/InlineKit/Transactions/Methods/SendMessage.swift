import Foundation
import GRDB

public struct SendMessageAttachment: Codable, Sendable {
  public enum ImageFormat: Codable, Sendable {
    case jpeg
    case png
  }
  
  enum AttachmentType: Codable, Sendable {
    case photo(ImageFormat, width: Int, height: Int)
    case file
  }
  
  public static func photo(format: ImageFormat, width: Int, height: Int, path: String, fileSize: Int, fileName: String? = nil) -> SendMessageAttachment {
    let fileName = fileName ?? UUID().uuidString + (format == .jpeg ? ".jpg" : ".png")
      
    return .init(type: .photo(.jpeg, width: width, height: height), filePath: path, fileName: fileName, fileSize: Int64(fileSize))
  }
  
  let type: AttachmentType
  let filePath: String
  let fileName: String?
  let fileSize: Int64
  
  // internal state
  package var id = UUID().uuidString // local file ID
  fileprivate var fileId: Int64? // when uploaded this gets filled
  fileprivate var randomId: Int64?
}

public struct SendMessageImageData: Codable, Sendable, Equatable, Hashable {
  /// <user temp dir>/path/to/image.jpeg
  let temporaryPath: String
  let format: ImageFormat
  let fileName: String
  
  public init(temporaryPath: String, format: ImageFormat, fileName: String = UUID().uuidString) {
    self.temporaryPath = temporaryPath
    self.format = format
    self.fileName = fileName
  }
  
  public enum ImageFormat: Codable, Sendable {
    case jpeg
    case png
  }
}

public struct TransactionSendMessage: Transaction {
  // Properties
  var text: String? = nil
  var peerId: Peer
  var chatId: Int64
  var attachments: [SendMessageAttachment]
  
  var replyToMessageId: Int64? = nil

  // Config
  public var id = UUID().uuidString
  var config = TransactionConfig.default
  var date = Date()

  // State
  var randomId: Int64
  var peerUserId: Int64? = nil
  var peerThreadId: Int64? = nil
  var temporaryMessageId: Int64

  public init(text: String?, peerId: Peer, chatId: Int64,  attachments: [SendMessageAttachment] = [], replyToMessageId: Int64? = nil) {
    self.text = text
    self.peerId = peerId
    self.chatId = chatId
self.attachments = attachments
    self.replyToMessageId = replyToMessageId
    randomId = Int64.random(in: Int64.min...Int64.max)
    peerUserId = if case .user(let id) = peerId { id } else { nil }
    peerThreadId = if case .thread(let id) = peerId { id } else { nil }
    temporaryMessageId = randomId
    
    if !attachments.isEmpty {
      self.attachments[0].randomId = randomId
      // TODO: handle multi-attachments
    }
  }

  // Methods
  func optimistic() {
    let fileId = attachments.first?.id
    let message = Message(
      messageId: temporaryMessageId,
      randomId: randomId,
      fromId: Auth.shared.getCurrentUserId()!,
      date: date,
      text: text,
      peerUserId: peerUserId,
      peerThreadId: peerThreadId,
      chatId: chatId,
      out: true,
      status: .sending,
      fileId: fileId
      repliedToMessageId: replyToMessageId
    )

    // When I remove this task, or make it a sync call, I get frame drops in very fast sending
    Task { @MainActor in
      let newMessage = try? (await AppDatabase.shared.dbWriter.write { db in
        if let attachment = attachments.first {
          print("has attachment")
          let file = File(fromAttachment: attachment)
          
          do {
            try file.save(db)
          } catch {
            Log.shared.error("Failed to save file", error: error)
          }
        }
        
        return try message.saveAndFetch(db)
      })
      
      if let message = newMessage {
        await MessagesPublisher.shared.messageAdded(message: message, peer: peerId)
      }
    }  //
  }

  func execute() async throws -> SendMessage {
    var fileUniqueId: String? = nil
    
    if let attachment = attachments.first {
      fileUniqueId = try await upload(attachment: attachment)
    }
    
    let result = try await ApiClient.shared.sendMessage(
      peerUserId: peerUserId,
      peerThreadId: peerThreadId,
      text: text,
      randomId: randomId,

      repliedToMessageId: replyToMessageId,
      date: date.timeIntervalSince1970,
      fileUniqueId: fileUniqueId
    )
     
    return result
  }
  
  // Private upload function
  private func upload(attachment: SendMessageAttachment) async throws -> String {
    return ""
  }
  
  func didSucceed(result: SendMessage) async {
    if let updates = result.updates {
      await UpdatesManager.shared.applyBatch(updates: updates)
    } else {
      Log.shared.error("No updates in send message response")
    }
  }

  func didFail(error: Error?) async {
    Log.shared.error("Failed to send message", error: error)

    // Mark as failed

    let _ = try? await AppDatabase.shared.dbWriter.write { db in
      try Message
        .filter(Column("randomId") == randomId && Column("fromId") == Auth.shared.getCurrentUserId()!)
        .updateAll(
          db,
          Column("status").set(to: MessageSendingStatus.failed.rawValue)
        )
    }
  }

  func rollback() async {
    // Remove from database
    let _ = try? await AppDatabase.shared.dbWriter.write { db in
      try Message
        .filter(Column("randomId") == randomId)
        .filter(Column("messageId") == temporaryMessageId)
        .deleteAll(db)
    }

    // Remove from cache
    await MessagesPublisher.shared
      .messagesDeleted(messageIds: [temporaryMessageId], peer: peerId)
  }
}
