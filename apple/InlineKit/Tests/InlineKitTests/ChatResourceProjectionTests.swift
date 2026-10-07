import Foundation
import GRDB
@testable import InlineKit
import InlineProtocol
import Testing

@Suite("Chat info canonical resource projections")
@MainActor
struct ChatResourceProjectionTests {
  @Test(
    "each tab retains sharing occurrences across raw pages without leaking other chats",
    arguments: ResourceKind.allCases
  )
  func sharingOccurrencesAcrossPages(_ kind: ResourceKind) async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let database = try AppDatabase(queue)
    try await queue.write { (db: Database) throws in
      try User(id: 1, email: nil, firstName: "Resources").insert(db)
      for chatID in [7, 8] as [Int64] {
        try Chat(id: chatID, date: Date(timeIntervalSince1970: 1), type: .thread, title: "Resources", spaceId: nil)
          .insert(db)
      }
      // A shared asset in another chat must never become a sharing occurrence here.
      _ = try Message.save(db, protocolMessage: kind.message(99, chatID: 8), materializeMissingReferences: true)
      var sticker = ResourceKind.media.message(91)
      sticker.isSticker = true
      _ = try Message.save(db, protocolMessage: sticker, materializeMissingReferences: true)
      var embedded = ResourceKind.media.message(92)
      embedded.clearMedia()
      embedded.blockContent = .with { $0.blocks = [.with { $0.image.ready = .with { $0.id = 300 } }] }
      _ = try Message.save(db, protocolMessage: embedded, materializeMissingReferences: true)
      try Self.admit(kind, ids: Array((31 ... 60).reversed()).map(Int64.init), offset: nil, db: db)
    }

    let media = ChatMediaViewModel(db: database, chatId: 7, peer: .thread(id: 7), excludeStickerMedia: true)
    let files = ChatDocumentsViewModel(db: database, chatId: 7, peer: .thread(id: 7))
    let voice = ChatVoiceMemosViewModel(db: database, chatId: 7, peer: .thread(id: 7))
    let links = ChatLinksViewModel(db: database, chatId: 7, peer: .thread(id: 7))
    let observedIDs: () -> [Int64] = {
      switch kind {
        case .media: media.mediaMessages.map(\.id)
        case .files: files.documentMessages.map(\.id)
        case .voice: voice.voiceMemoMessages.map(\.id)
        case .links: links.linkMessages.map(\.id)
      }
    }
    switch kind {
      case .media: media.activate()
      case .files: files.activate()
      case .voice: voice.activate()
      case .links: links.activate()
    }
    await Self.waitForRows(Array((31 ... 60).reversed()).map(Int64.init), read: observedIDs)

    try await queue.write { (db: Database) throws in
      try Self.admit(kind, ids: Array((1 ... 30).reversed()).map(Int64.init), offset: 31, db: db)
    }
    // The real tab has a 50-row viewport. Twenty rows from the older raw page
    // remain distinct occurrences instead of collapsing under the shared asset.
    let visibleIDs = Array((11 ... 60).reversed()).map(Int64.init)
    await Self.waitForRows(visibleIDs, read: observedIDs)
    #expect(Set(observedIDs()).count == 50)
    let displayedIDs: [Int64] = switch kind {
      case .media: media.groupedMediaMessages.flatMap(\.messages).map(\.id)
      case .files: files.groupedDocumentMessages.flatMap(\.messages).map(\.id)
      case .voice: voice.groupedVoiceMemoMessages.flatMap(\.messages).map(\.id)
      case .links: links.groupedLinkMessages.flatMap(\.messages).map(\.id)
    }
    // Page boundaries remain numeric even when imported timestamps run backward.
    #expect(displayedIDs == Array(visibleIDs.reversed()))
    switch kind {
      case .media:
        #expect(Set(media.mediaMessages.compactMap { $0.photo?.photo.photoId }) == [300])
        #expect(Set(media.mediaMessages.compactMap { $0.video?.video.videoId }) == [301])
        #expect(Set(media.mediaMessages.compactMap { $0.photo?.photo.id }).count == 1)
        #expect(Set(media.mediaMessages.compactMap { $0.video?.video.id }).count == 1)
        #expect(media.mediaMessages.allSatisfy {
          $0.message.chatId == 7 && ($0.message.messageId.isMultiple(of: 2)
            ? $0.message.photoId == $0.photo?.photo.photoId && $0.photo?.photo.photoId == 300 && $0.video == nil
            : $0.message.videoId == $0.video?.video.videoId && $0.video?.video.videoId == 301 && $0.photo == nil)
        })
      case .files:
        #expect(Set(files.documentMessages.compactMap(\.document.document.id)).count == 1)
        #expect(Set(files.documentMessages.map(\.document.document.documentId)) == [400])
        #expect(files.documentMessages.allSatisfy {
          $0.message.chatId == 7 && $0.document.document.documentId == 400 &&
            $0.message.documentId == $0.document.document.documentId && $0.document.document.fileName == "Repeated.pdf"
        })
      case .voice:
        #expect(voice.voiceMemoMessages
          .allSatisfy { $0.message.chatId == 7 && $0.voice.voiceID == 500 && $0.voice.duration == 12 })
      case .links:
        #expect(links.linkMessages
          .allSatisfy {
            $0.message.chatId == 7 && $0.urlPreview?.id == 600 && $0.urlPreview?.url == "https://inline.chat/resources"
          })
    }
    try await queue.read { (db: Database) throws in
      let retained = try Message.filter(Message.Columns.chatId == 7)
        .filter(Message.Columns.messageId <= 60).fetchAll(db)
      #expect(Set(retained.map(\.messageId)) == Set((1 ... 60).map(Int64.init)))
      #expect(try MessageHistoryCoverageStore.holes(db, chatId: 7, scope: kind.scope).isEmpty)
      #expect(try MessageHistoryCoverageStore.holes(db, chatId: 7).count == 1)
      if kind == .media {
        let all = try MediaMessage.queryRequest(excludingStickers: true).filter(Message.Columns.chatId == 7)
          .fetchAll(db)
        #expect(Set(all.map(\.id)) == Set((1 ... 60).map(Int64.init)))
      } else if kind == .files {
        let all = try DocumentMessage.queryRequest().filter(Message.Columns.chatId == 7).fetchAll(db)
        #expect(Set(all.map(\.id)) == Set((1 ... 60).map(Int64.init)))
      } else if kind == .links {
        let all = try LinkMessage.queryRequest(chatId: 7).fetchAll(db)
        #expect(Set(all.map(\.id)) == Set((1 ... 60).map(Int64.init)))
      }
    }
  }

  private nonisolated static func admit(_ kind: ResourceKind, ids: [Int64], offset: Int64?, db: Database) throws {
    var transaction = SearchMessagesTransaction(
      peer: .thread(id: 7),
      queries: [],
      offsetID: offset,
      limit: 30,
      filter: kind.scope.filter
    )
    transaction.context.admissionToken = try HistoryPageAdmissionToken.capture(db, chatId: 7)
    var page = InlineProtocol.SearchMessagesResult()
    page.seq = 0
    page.messages = ids.map { kind.message($0) }
    try SearchMessagesTransaction.apply(page, context: transaction.context, db: db)
  }

  private static func waitForRows(_ expected: [Int64], read: () -> [Int64]) async {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(2)
    while read() != expected, clock.now < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(read() == expected)
  }
}

enum ResourceKind: CaseIterable, Sendable {
  case media, files, voice, links

  var scope: MessageHistoryScope {
    switch self {
      case .media: .media
      case .files: .files
      case .voice: .voice
      case .links: .links
    }
  }

  func message(_ id: Int64, chatID: Int64 = 7) -> InlineProtocol.Message {
    .with {
      $0.id = id
      $0.chatID = chatID
      $0.fromID = 1
      $0.peerID = .with { $0.chat.chatID = chatID }
      $0.date = 60 - id
      $0.rev = 1
      switch self {
        case .media:
          if id.isMultiple(of: 2) {
            $0.media.photo.photo = .with { $0.id = 300 }
          } else {
            $0.media.video.video = .with { $0.id = 301 }
          }
        case .files:
          $0.media.document.document = .with { $0.id = 400
            $0.fileName = "Repeated.pdf"
            $0.mimeType = "application/pdf"
          }
        case .voice:
          $0.media.voice.voice = .with { $0.id = 500
            $0.duration = 12
            $0.mimeType = "audio/ogg"
          }
        case .links:
          $0.message = "https://inline.chat/resources"
          $0.hasLink_p = true
          $0.attachments.attachments = [.with {
            $0.id = 1_000 + chatID * 100 + id
            $0.urlPreview = .with { $0.id = 600
              $0.url = "https://inline.chat/resources"
              $0.title = "Resources"
            }
          }]
      }
    }
  }
}
