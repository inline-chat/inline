import Auth
import Foundation
import GRDB
import InlineProtocol
import Logger
import MultipartFormDataKit
import RealtimeAPI

#if os(iOS)
import UIKit
#endif

public struct SendMessageAttachment: Codable, Sendable {
  let media: FileMediaItem

  // internal state
  fileprivate var uploaded: Bool = false
  fileprivate var randomId: Int64?
}

public struct TransactionSendMessage: Transaction {
  // Properties
  public var text: String? = nil
  public var peerId: Peer
  public var chatId: Int64
  public var attachments: [SendMessageAttachment]
  public var replyToMsgId: Int64? = nil
  public var isSticker: Bool? = nil

  // Config
  public var id = UUID().uuidString
  public var config = TransactionConfig.default
  public var date = Date()

  // State
  public var randomId: Int64
  public var peerUserId: Int64? = nil
  public var peerThreadId: Int64? = nil
  public var temporaryMessageId: Int64

  public init(
    text: String?,
    peerId: Peer,
    chatId: Int64,
    mediaItems: [FileMediaItem] = [],
    replyToMsgId: Int64? = nil,
    isSticker: Bool? = nil
  ) {
    self.text = text
    self.peerId = peerId
    self.chatId = chatId
    self.isSticker = isSticker
    attachments = mediaItems.map { SendMessageAttachment(media: $0) }
    self.replyToMsgId = replyToMsgId
    randomId = Int64.random(in: 0 ... Int64.max)
    peerUserId = if case let .user(id) = peerId { id } else { nil }
    peerThreadId = if case let .thread(id) = peerId { id } else { nil }
    temporaryMessageId = -1 * randomId

    if !attachments.isEmpty {
      // iterate over attachments and attach random id to all
      for i in 0 ..< attachments.count {
        if i == 0 {
          attachments[0].randomId = randomId
        } else {
          Log.shared.warning("Multiple attachments in send message transaction not supported yet")
          // self.attachments[i].randomId = Int64.random(in: Int64.min ... Int64.max)
        }
      }
    }
  }

  // Methods
  public func optimistic() {
    let media = attachments.first?.media
    Log.shared.debug("Optimistic send message \(media.debugDescription)")
    let message = Message(
      messageId: temporaryMessageId,
      randomId: randomId,
      fromId: Auth.getCurrentUserId()!,
      date: date,
      text: text,
      peerUserId: peerUserId,
      peerThreadId: peerThreadId,
      chatId: chatId,
      out: true,
      status: .sending,
      repliedToMessageId: replyToMsgId,
      fileId: nil,
      photoId: media?.asPhotoId(),
      videoId: media?.asVideoId(),
      documentId: media?.asDocumentId(),
      transactionId: id,
      isSticker: isSticker
    )

    // When I remove this task, or make it a sync call, I get frame drops in very fast sending
    // (mo a few months later) TRADE OFFS BABY
    // Task { @MainActor in

    Task(priority: .userInitiated) { // off main actor for db write
      let newMessage = try? AppDatabase.shared.dbWriter.write { db in
        do {
          // Save message
          try message.save(db)

          // Update last message id
          try Chat
            .updateLastMsgId(
              db,
              chatId: message.chatId,
              lastMsgId: message.messageId,
              date: message.date
            )

          // Fetch full message for update
          return try FullMessage.queryRequest()
            .filter(Column("messageId") == message.messageId)
            .filter(Column("chatId") == message.chatId)
            .fetchOne(db)
        } catch {
          Log.shared.error("Failed to save and fetch message", error: error)
          return nil
        }
      }

      Task(priority: .userInitiated) { @MainActor in
        if let newMessage {
          MessagesPublisher.shared.messageAddedSync(fullMessage: newMessage, peer: peerId)
        } else {
          Log.shared.error("Failed to save message and push update")
        }
      }
    }
  }

  public func execute() async throws -> [InlineProtocol.Update] {
    // clear typing...
    Task {
      await ComposeActions.shared.stoppedTyping(for: peerId)
    }

    let date = Date()
    var inputMedia: InputMedia? = nil

    // upload attachments and construct input media
    if let attachment = attachments.first {
      switch attachment.media {
        case let .photo(photoInfo):
//          let clearUploadState = await ComposeActions.shared.startPhotoUpload(for: peerId)
//          defer {
//            Task { @MainActor in
//              clearUploadState()
//            }
//          }

          let localPhotoId = try await FileUploader.shared.uploadPhoto(photoInfo: photoInfo)
          if let photoServerId = try await FileUploader.shared.waitForUpload(photoLocalId: localPhotoId)?.photoId {
            inputMedia = .fromPhotoId(photoServerId)
          }

        case let .video(videoInfo):
          // Start video upload status
//          let clearUploadState = await ComposeActions.shared.startVideoUpload(for: peerId)
//          defer {
//            Task { @MainActor in
//              clearUploadState()
//            }
//          }

          let localVideoId = try await FileUploader.shared.uploadVideo(videoInfo: videoInfo)
          if let videoServerId = try await FileUploader.shared.waitForUpload(videoLocalId: localVideoId)?.videoId {
            inputMedia = .fromVideoId(videoServerId)
          }

        case let .document(documentInfo):
          // Start document upload status
//          let clearUploadState = await ComposeActions.shared.startDocumentUpload(for: peerId)
//          defer {
//            // Clear the upload status
//            Task { @MainActor in
//              clearUploadState()
//            }
//          }

          let localDocumentId = try await FileUploader.shared.uploadDocument(documentInfo: documentInfo)
          if let documentServerId = try await FileUploader.shared.waitForUpload(documentLocalId: localDocumentId)?
            .documentId
          {
            inputMedia = .fromDocumentId(documentServerId)
          }
      }
    }

    // input for send message
    let input: SendMessageInput = .with {
      $0.peerID = peerId.toInputPeer()
      $0.randomID = randomId
      $0.temporarySendDate = Int64(date.timeIntervalSince1970.rounded())
      $0.isSticker = isSticker ?? false

      if let text { $0.message = text }
      if let replyToMsgId { $0.replyToMsgID = replyToMsgId }
      if let inputMedia { $0.media = inputMedia }
    }

    let result_ = try await Realtime.shared.invoke(
      .sendMessage,
      input: .sendMessage(input),
      discardIfNotConnected: true
    )

    guard case let .sendMessage(result) = result_ else {
      throw SendMessageError.failed
    }

    return result.updates
  }

  public func shouldRetryOnFail(error: Error) -> Bool {
    if let error = error as? RealtimeAPIError {
      switch error {
        case let .rpcError(ec, msg, code):
          switch code {
            case 400, 401:
              return false

            default:
              return true
          }
        default:
          return true
      }
    }

    return true
  }

  public func didSucceed(result: [InlineProtocol.Update]) async {
    // await Realtime.shared.updates.applyBatch(updates: result)

    #if os(iOS)
    Task(priority: .userInitiated) { @MainActor in
      SendMessageFeedback.shared.playHapticFeedback()
    }
    #endif
  }

  public func didFail(error: Error?) async {
    Log.shared.error("Failed to send message", error: error)

    // Mark as failed
    do {
      let message = try await AppDatabase.shared.dbWriter.write { db in
        try Message
          .filter(Column("randomId") == randomId && Column("fromId") == Auth.getCurrentUserId()!)
          .updateAll(
            db,
            Column("status").set(to: MessageSendingStatus.failed.rawValue)
          )
        return try Message.fetchOne(db, key: ["messageId": temporaryMessageId, "chatId": chatId])
      }

      // Update UI
      if let message {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
          MessagesPublisher.shared
            .messageUpdatedSync(message: message, peer: peerId, animated: true)
        }
      }
    } catch {
      Log.shared.error("Failed to update message status on failure", error: error)
    }
  }

  public func rollback() async {
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

  enum SendMessageError: Error {
    case failed
  }
}
