import Foundation
import GRDB
import InlineProtocol
import Testing

@testable import InlineKit

@Suite("Rich message effective media")
struct RichMessageEffectiveMediaTests {
  private let chatId: Int64 = 7_700
  private let userId: Int64 = 42
  private let date = Date(timeIntervalSince1970: 1_782_129_600)

  @Test("extracts internal media refs from nested rich blocks in render order")
  func extractsNestedMediaRefs() {
    let rich = RichMessage.with {
      $0.blocks = [
        photoBlock(10),
        detailsBlock([
          videoBlock(20),
          collageBlock([
            photoBlock(10),
            documentBlock(30),
          ]),
        ]),
        embedBlock(posterPhotoId: 35),
        embedPostBlock(authorPhotoId: 40, blocks: [
          audioBlock(voiceId: 50),
        ]),
        linkPreviewBlock(photoId: 60),
      ]
    }

    #expect(rich.effectiveMediaRefs == [
      .photo(10),
      .video(20),
      .document(30),
      .photo(35),
      .photo(40),
      .voice(50),
      .photo(60),
    ])
  }

  @Test("stable signature is deterministic and changes with canonical rich payload")
  func stableSignatureTracksCanonicalPayload() {
    let first = RichMessage.with {
      $0.version = 1
      $0.fallbackText = "hello"
      $0.blocks = [paragraphBlock("hello", id: "p1")]
    }
    let same = RichMessage.with {
      $0.version = 1
      $0.fallbackText = "hello"
      $0.blocks = [paragraphBlock("hello", id: "p1")]
    }
    let changed = RichMessage.with {
      $0.version = 1
      $0.fallbackText = "hello!"
      $0.blocks = [paragraphBlock("hello!", id: "p1")]
    }

    #expect(first.stableSignature == same.stableSignature)
    #expect(first.stableSignature != changed.stableSignature)
    #expect(first.stableSignature.contains(":"))
  }

  @Test("shared media query includes root and rich photos and videos")
  func sharedMediaIncludesRootAndRichMedia() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      try seedBase(db)
      try seedPhoto(db, photoId: 101)
      try seedPhoto(db, photoId: 102)
      try seedVideo(db, videoId: 202)
      try seedMessage(
        db,
        messageId: 1,
        richText: RichMessage.with {
          $0.blocks = [
            photoBlock(101),
            videoBlock(202),
          ]
        }
      )
      try seedMessage(db, messageId: 2, photoId: 102)

      let messages = try MediaMessage.effectiveMessages(in: db, chatId: chatId)

      #expect(messages.map(\.message.messageId) == [2, 1, 1])
      #expect(messages.map(\.id) == ["photo:2", "photo:1", "video:1"])
      if case let .photo(photoInfo)? = messages.first?.kind {
        #expect(photoInfo.photo.photoId == 102)
        #expect(photoInfo.bestPhotoSize()?.cdnUrl == "https://cdn.inline.test/p102.jpg")
      } else {
        Issue.record("expected first media item to be the root photo")
      }
      if case let .photo(photoInfo)? = messages.dropFirst().first?.kind {
        #expect(photoInfo.photo.photoId == 101)
        #expect(photoInfo.bestPhotoSize()?.cdnUrl == "https://cdn.inline.test/p101.jpg")
      } else {
        Issue.record("expected second media item to be the rich photo")
      }
      if case let .video(videoInfo)? = messages.dropFirst(2).first?.kind {
        #expect(videoInfo.video.videoId == 202)
        #expect(videoInfo.video.cdnUrl == "https://cdn.inline.test/v202.mp4")
      } else {
        Issue.record("expected third media item to be the rich video")
      }
    }
  }

  @Test("document query includes root and rich documents")
  func documentQueryIncludesRootAndRichDocuments() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      try seedBase(db)
      let document = try seedDocument(db, documentId: 303)
      let rootDocument = try seedDocument(db, documentId: 304)
      try seedMessage(
        db,
        messageId: 2,
        richText: RichMessage.with {
          $0.blocks = [documentBlock(303)]
        }
      )
      try seedMessage(db, messageId: 3, documentId: 304)

      let messages = try DocumentMessage.effectiveMessages(in: db, chatId: chatId)

      #expect(messages.map(\.message.messageId) == [3, 2])
      #expect(messages.map(\.document.document) == [rootDocument, document])
    }
  }

  @Test("effective media query includes root and rich voice refs")
  func effectiveMediaQueryIncludesVoiceRefs() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      try seedBase(db)
      try seedMessage(db, messageId: 4, voiceId: 404)
      try seedMessage(
        db,
        messageId: 5,
        richText: RichMessage.with {
          $0.blocks = [
            audioBlock(voiceId: 505),
            detailsBlock([
              audioBlock(voiceId: 505),
            ]),
          ]
        }
      )

      let hits = try MessageEffectiveMediaQuery.refs(in: db, chatId: chatId, kinds: [.voice])

      #expect(hits.map(\.message.messageId) == [5, 4])
      #expect(hits.map(\.ref) == [.voice(505), .voice(404)])
      #expect(hits.map(\.source) == [.rich, .root])
    }
  }

  @Test("effective media query prefers root attachment over duplicate rich refs")
  func effectiveMediaQueryPrefersRootAttachmentOverDuplicateRichRefs() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      try seedBase(db)
      try seedPhoto(db, photoId: 606)
      _ = try seedDocument(db, documentId: 707)
      try seedMessage(
        db,
        messageId: 6,
        richText: RichMessage.with {
          $0.blocks = [
            photoBlock(606),
            documentBlock(707),
            audioBlock(voiceId: 808),
          ]
        },
        photoId: 606,
        documentId: 707,
        voiceId: 808
      )

      let hits = try MessageEffectiveMediaQuery.refs(
        in: db,
        chatId: chatId,
        kinds: [.photo, .document, .voice]
      )

      #expect(hits.map(\.ref) == [.document(707), .photo(606), .voice(808)])
      #expect(hits.map(\.source) == [.root, .root, .root])
    }
  }

  @Test("effective media query keeps the same media ref when reused by separate messages")
  func effectiveMediaQueryKeepsSameRefAcrossMessages() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      try seedBase(db)
      try seedPhoto(db, photoId: 909)
      try seedMessage(
        db,
        messageId: 7,
        richText: RichMessage.with {
          $0.blocks = [
            photoBlock(909),
            photoBlock(909),
          ]
        }
      )
      try seedMessage(
        db,
        messageId: 8,
        richText: RichMessage.with {
          $0.blocks = [photoBlock(909)]
        }
      )

      let hits = try MessageEffectiveMediaQuery.refs(in: db, chatId: chatId, kinds: [.photo])

      #expect(hits.map(\.message.messageId) == [8, 7])
      #expect(hits.map(\.ref) == [.photo(909), .photo(909)])
      #expect(hits.map(\.source) == [.rich, .rich])
    }
  }

  private func makeInMemoryDB() throws -> DatabaseQueue {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)
    return queue
  }

  private func seedBase(_ db: Database) throws {
    try User(id: userId, email: "rich-media@example.com", firstName: "Rich", lastName: nil, username: "rich_media")
      .insert(db)
    try Chat(
      id: chatId,
      date: date,
      type: .thread,
      title: "Rich Media",
      spaceId: nil
    ).insert(db)
  }

  private func seedMessage(
    _ db: Database,
    messageId: Int64,
    richText: RichMessage? = nil,
    photoId: Int64? = nil,
    documentId: Int64? = nil,
    voiceId: Int64? = nil
  ) throws {
    let contentPayload: Client_MessageContentPayload? = if let voiceId {
      Client_MessageContentPayload.with {
        $0.voice = Client_MessageVoiceContent.with { voice in
          voice.voiceID = voiceId
          voice.duration = 7
          voice.waveform = Data([1, 4, 8, 4, 1])
          voice.mimeType = "audio/ogg"
          voice.cdnURL = "https://cdn.inline.test/voice-\(voiceId).ogg"
          voice.size = 2048
        }
      }
    } else {
      nil
    }

    var message = Message(
      messageId: messageId,
      fromId: userId,
      date: date.addingTimeInterval(TimeInterval(messageId)),
      text: "rich media",
      peerUserId: nil,
      peerThreadId: chatId,
      chatId: chatId,
      photoId: photoId,
      documentId: documentId,
      contentPayload: contentPayload,
      richText: richText
    )
    try message.saveMessage(db)
  }

  private func seedPhoto(_ db: Database, photoId: Int64) throws {
    let photo = try Photo(photoId: photoId, date: date, format: .jpeg).insertAndFetch(db)
    try PhotoSize(photoId: try #require(photo.id), type: "f", width: 640, height: 480, cdnUrl: "https://cdn.inline.test/p\(photoId).jpg")
      .insert(db)
  }

  private func seedVideo(_ db: Database, videoId: Int64) throws {
    let video = Video(
      videoId: videoId,
      date: date,
      width: 1280,
      height: 720,
      duration: 4,
      size: 2048,
      thumbnailPhotoId: nil,
      cdnUrl: "https://cdn.inline.test/v\(videoId).mp4",
      localPath: nil
    )
    try video.insert(db)
  }

  @discardableResult
  private func seedDocument(_ db: Database, documentId: Int64) throws -> InlineKit.Document {
    let document = InlineKit.Document(
      documentId: documentId,
      date: date,
      fileName: "report-\(documentId).pdf",
      mimeType: "application/pdf",
      size: 4096,
      cdnUrl: "https://cdn.inline.test/d\(documentId).pdf",
      localPath: nil,
      thumbnailPhotoId: nil
    )
    return try document.insertAndFetch(db)
  }

  private func photoBlock(_ photoId: Int64) -> RichBlock {
    RichBlock.with {
      $0.blockID = "photo-\(photoId)"
      $0.photo = RichPhotoBlock.with { block in
        block.media = RichMediaRef.with { ref in
          ref.photoID = photoId
        }
      }
    }
  }

  private func paragraphBlock(_ value: String, id: String) -> RichBlock {
    RichBlock.with {
      $0.blockID = id
      $0.paragraph = RichParagraphBlock.with { block in
        block.text = [
          RichText.with { text in
            text.text = value
          }
        ]
      }
    }
  }

  private func videoBlock(_ videoId: Int64) -> RichBlock {
    RichBlock.with {
      $0.blockID = "video-\(videoId)"
      $0.video = RichVideoBlock.with { block in
        block.media = RichMediaRef.with { ref in
          ref.videoID = videoId
        }
      }
    }
  }

  private func documentBlock(_ documentId: Int64) -> RichBlock {
    RichBlock.with {
      $0.blockID = "document-\(documentId)"
      $0.document = RichDocumentBlock.with { block in
        block.media = RichMediaRef.with { ref in
          ref.documentID = documentId
        }
      }
    }
  }

  private func audioBlock(voiceId: Int64) -> RichBlock {
    RichBlock.with {
      $0.blockID = "voice-\(voiceId)"
      $0.audio = RichAudioBlock.with { block in
        block.media = RichMediaRef.with { ref in
          ref.voiceID = voiceId
        }
      }
    }
  }

  private func detailsBlock(_ blocks: [RichBlock]) -> RichBlock {
    RichBlock.with {
      $0.blockID = "details"
      $0.details = RichDetailsBlock.with { block in
        block.blocks = blocks
      }
    }
  }

  private func collageBlock(_ items: [RichBlock]) -> RichBlock {
    RichBlock.with {
      $0.blockID = "collage"
      $0.collage = RichCollageBlock.with { block in
        block.items = items
      }
    }
  }

  private func embedBlock(posterPhotoId: Int64) -> RichBlock {
    RichBlock.with {
      $0.blockID = "embed"
      $0.embed = RichEmbedBlock.with { block in
        block.poster = RichMediaRef.with { ref in
          ref.photoID = posterPhotoId
        }
      }
    }
  }

  private func embedPostBlock(authorPhotoId: Int64, blocks: [RichBlock]) -> RichBlock {
    RichBlock.with {
      $0.blockID = "embed-post"
      $0.embedPost = RichEmbedPostBlock.with { block in
        block.authorPhoto = RichMediaRef.with { ref in
          ref.photoID = authorPhotoId
        }
        block.blocks = blocks
      }
    }
  }

  private func linkPreviewBlock(photoId: Int64) -> RichBlock {
    RichBlock.with {
      $0.blockID = "link-preview"
      $0.linkPreview = RichLinkPreviewBlock.with { block in
        block.media = RichMediaRef.with { ref in
          ref.photoID = photoId
        }
      }
    }
  }
}
