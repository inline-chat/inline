import Foundation
import GRDB
@testable import InlineKit
import Testing

@Suite("Audio document support")
struct AudioDocumentSupportTests {
  @Test("accepts verified MIME types", arguments: [
    "audio/mpeg",
    "audio/mp3",
    "audio/mp4",
    "audio/x-m4a",
    "audio/wav",
    "audio/x-wav",
    " Audio/MPEG; charset=binary ",
  ])
  func acceptsVerifiedMimeTypes(_ mimeType: String) {
    #expect(AudioDocumentSupport.isPlayableAudio(mimeType: mimeType, fileName: nil))
  }

  @Test("accepts verified filename extensions", arguments: [
    "track.mp3",
    "recording.WAV",
    "song.m4a",
  ])
  func acceptsVerifiedExtensions(_ fileName: String) {
    #expect(AudioDocumentSupport.isPlayableAudio(mimeType: nil, fileName: fileName))
  }

  @Test("keeps unverified audio formats as documents")
  func rejectsUnverifiedFormats() {
    #expect(!AudioDocumentSupport.isPlayableAudio(mimeType: "audio/ogg", fileName: "track.ogg"))
    #expect(!AudioDocumentSupport.isPlayableAudio(mimeType: "audio/opus", fileName: "track.opus"))
  }

  @Test("audio reply previews use the filename instead of Document")
  func audioReplyPreview() {
    #expect(MessagePreviewText.document(
      fileName: "  Artist - Song.mp3  ",
      mimeType: "application/octet-stream"
    ) == "🎵 Artist - Song.mp3")
    #expect(MessagePreviewText.document(
      fileName: nil,
      mimeType: "audio/mpeg"
    ) == "🎵 Audio")
    #expect(MessagePreviewText.document(
      fileName: "Artist - Song.mp3",
      mimeType: "audio/mpeg",
      includesEmoji: false
    ) == "Artist - Song.mp3")
  }

  @Test("ordinary and unverified audio documents keep document previews")
  func nonPlayableDocumentPreview() {
    #expect(MessagePreviewText.document(
      fileName: "notes.pdf",
      mimeType: "application/pdf"
    ) == "📄 notes.pdf")
    #expect(MessagePreviewText.document(
      fileName: "track.ogg",
      mimeType: "audio/ogg"
    ) == "📄 track.ogg")
  }

  @Test("full-message replies load audio document metadata")
  func replyQueryLoadsAudioDocument() throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)

    try queue.write { db in
      try User(id: 1, email: "sender@example.com", firstName: "Sender").insert(db)
      try Chat(
        id: 44,
        date: Date(timeIntervalSince1970: 1),
        type: .thread,
        title: "Music",
        spaceId: nil
      ).insert(db)
      try Document(
        id: nil,
        documentId: 77,
        date: Date(timeIntervalSince1970: 2),
        fileName: "Artist - Song.mp3",
        mimeType: "audio/mpeg",
        size: 9_000_000,
        cdnUrl: nil,
        localPath: nil,
        thumbnailPhotoId: nil
      ).insert(db)

      var audioMessage = Message(
        messageId: 101,
        fromId: 1,
        date: Date(timeIntervalSince1970: 2),
        text: nil,
        peerUserId: nil,
        peerThreadId: 44,
        chatId: 44,
        documentId: 77
      )
      try audioMessage.saveMessage(db)

      var reply = Message(
        messageId: 102,
        fromId: 1,
        date: Date(timeIntervalSince1970: 3),
        text: "Love it",
        peerUserId: nil,
        peerThreadId: 44,
        chatId: 44,
        repliedToMessageId: 101
      )
      try reply.saveMessage(db)

      let fullReply = try #require(try FullMessage.queryRequest(currentUserId: 1)
        .filter(Message.Columns.chatId == 44)
        .filter(Message.Columns.messageId == 102)
        .fetchOne(db))

      #expect(fullReply.repliedToMessage?.document?.fileName == "Artist - Song.mp3")
      #expect(fullReply.repliedToMessage?.document?.mimeType == "audio/mpeg")
    }
  }
}
