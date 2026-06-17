import Foundation
import InlineProtocol
import Testing

@testable import InlineKit

@Suite("Drafts2")
struct Drafts2Tests {
  @Test("text updates are immediately loadable from cache")
  func textUpdatesAreImmediatelyLoadableFromCache() {
    let drafts = Drafts2(database: AppDatabase.empty())
    let peer: InlineKit.Peer = .user(id: 1)

    let revision = drafts.updateText(peer: peer, text: "hello")
    let snapshot = drafts.load(peer: peer)

    #expect(snapshot?.text == "hello")
    #expect(snapshot?.revision == revision)
  }

  @Test("stale entity saves are ignored")
  func staleEntitySavesAreIgnored() {
    let drafts = Drafts2(database: AppDatabase.empty())
    let peer: InlineKit.Peer = .thread(id: 2)

    let staleRevision = drafts.updateText(peer: peer, text: "hello mo")
    let currentRevision = drafts.updateText(peer: peer, text: "hello mo!")

    #expect(!drafts.updateEntities(peer: peer, entities: mentionEntities(), forRevision: staleRevision))
    #expect(drafts.load(peer: peer)?.entities == nil)

    #expect(drafts.updateEntities(peer: peer, entities: mentionEntities(), forRevision: currentRevision))
    #expect(drafts.load(peer: peer)?.entities?.entities.count == 1)
  }

  @Test("plain text updates preserve existing entities until replacement")
  func plainTextUpdatesPreserveExistingEntitiesUntilReplacement() {
    let drafts = Drafts2(database: AppDatabase.empty())
    let peer: InlineKit.Peer = .thread(id: 22)

    let revision = drafts.updateText(peer: peer, text: "hello mo")
    #expect(drafts.updateEntities(peer: peer, entities: mentionEntities(), forRevision: revision))

    drafts.updateText(peer: peer, text: "hello mo!")

    #expect(drafts.load(peer: peer)?.entities?.entities.count == 1)
  }

  @Test("empty text clears entities even when attachments keep draft alive")
  func emptyTextClearsEntitiesEvenWhenAttachmentsKeepDraftAlive() async throws {
    let db = AppDatabase.empty()
    let drafts = Drafts2(database: db)
    let peer: InlineKit.Peer = .thread(id: 23)

    let revision = drafts.updateText(peer: peer, text: "hello mo")
    #expect(drafts.updateEntities(peer: peer, entities: mentionEntities(), forRevision: revision))
    drafts.appendAttachment(peer: peer, media: .document(documentInfo(id: -230)))

    drafts.updateText(peer: peer, text: "")
    await drafts.flush()

    let reloaded = Drafts2(database: db).load(peer: peer)
    #expect(reloaded?.text == "")
    #expect(reloaded?.entities == nil)
    #expect(reloaded?.attachments.count == 1)
  }

  @Test("legacy draft message imports into Drafts2")
  func legacyDraftMessageImportsIntoDrafts2() {
    let drafts = Drafts2(database: AppDatabase.empty())
    let peer: InlineKit.Peer = .user(id: 3)
    let legacy = DraftMessage.with {
      $0.text = "legacy draft"
      $0.entities = mentionEntities()
    }

    let snapshot = drafts.load(peer: peer, legacyDraftMessage: legacy)

    #expect(snapshot?.text == "legacy draft")
    #expect(snapshot?.entities?.entities.count == 1)
  }

  @Test("attachments stay with empty text and round trip through storage")
  func attachmentsStayWithEmptyTextAndRoundTripThroughStorage() async throws {
    let db = AppDatabase.empty()
    let drafts = Drafts2(database: db)
    let peer: InlineKit.Peer = .thread(id: 4)
    let media = FileMediaItem.document(documentInfo(id: -40))

    let attachment = drafts.appendAttachment(peer: peer, media: media)
    drafts.updateText(peer: peer, text: "")

    let cached = drafts.load(peer: peer)
    #expect(cached?.text == "")
    #expect(cached?.attachments.map(\.id) ?? [] == [attachment.id])

    let stored = await waitForStoredDraft(db: db, peer: peer)
    #expect(stored?.attachments.map(\.id) ?? [] == [attachment.id])

    let freshDrafts = Drafts2(database: db)
    let reloaded = freshDrafts.load(peer: peer)
    #expect(reloaded?.attachments.map(\.id) ?? [] == [attachment.id])

    let sendSnapshot = try await freshDrafts.prepareSend(peer: peer)
    #expect(sendSnapshot.text == nil)
    #expect(sendSnapshot.mediaItems.count == 1)
  }

  @Test("flush stores latest staged text without blocking update calls")
  func flushStoresLatestStagedText() async throws {
    let db = AppDatabase.empty()
    let drafts = Drafts2(database: db)
    let peer: InlineKit.Peer = .user(id: 5)

    for index in 0..<200 {
      drafts.updateText(peer: peer, text: "draft \(index)")
    }

    await drafts.flush()

    let freshDrafts = Drafts2(database: db)
    #expect(freshDrafts.load(peer: peer)?.text == "draft 199")
  }

  @Test("clear removes persisted row after flush")
  func clearRemovesPersistedRowAfterFlush() async throws {
    let db = AppDatabase.empty()
    let drafts = Drafts2(database: db)
    let peer: InlineKit.Peer = .thread(id: 6)

    drafts.updateText(peer: peer, text: "temporary")
    await drafts.flush()
    #expect(Drafts2(database: db).load(peer: peer)?.text == "temporary")

    drafts.clear(peer: peer)
    await drafts.flush()

    #expect(Drafts2(database: db).load(peer: peer) == nil)
  }

  @Test("removing attachment preserves remaining order")
  func removingAttachmentPreservesRemainingOrder() async throws {
    let db = AppDatabase.empty()
    let drafts = Drafts2(database: db)
    let peer: InlineKit.Peer = .thread(id: 7)

    let first = drafts.appendAttachment(peer: peer, media: .document(documentInfo(id: -71)))
    let removed = drafts.appendAttachment(peer: peer, media: .document(documentInfo(id: -72)))
    let third = drafts.appendAttachment(peer: peer, media: .document(documentInfo(id: -73)))
    drafts.removeAttachment(peer: peer, id: removed.id)
    await drafts.flush()

    let reloaded = Drafts2(database: db).load(peer: peer)
    #expect(reloaded?.attachments.map(\.id) ?? [] == [first.id, third.id])
  }

  @Test("voice attachments round trip through draft storage")
  func voiceAttachmentsRoundTripThroughDraftStorage() async throws {
    let db = AppDatabase.empty()
    let drafts = Drafts2(database: db)
    let peer: InlineKit.Peer = .user(id: 8)
    let voice = Client_MessageVoiceContent.with {
      $0.voiceID = -80
      $0.duration = 3
      $0.waveform = Data([1, 8, 16])
      $0.localRelativePath = "voice/draft.m4a"
    }

    let attachment = drafts.appendAttachment(peer: peer, media: .voice(voice))
    await drafts.flush()

    let reloaded = Drafts2(database: db).load(peer: peer)
    #expect(reloaded?.attachments.map(\.id) ?? [] == [attachment.id])

    guard case let .voice(reloadedVoice)? = reloaded?.attachments.first?.media else {
      Issue.record("Expected voice attachment")
      return
    }
    #expect(reloadedVoice.voiceID == voice.voiceID)
    #expect(reloadedVoice.waveform == voice.waveform)
  }

  private func mentionEntities() -> MessageEntities {
    var entity = MessageEntity()
    entity.type = .mention
    entity.offset = 6
    entity.length = 2
    entity.mention = MessageEntity.MessageEntityMention.with {
      $0.userID = 42
    }

    return MessageEntities.with {
      $0.entities = [entity]
    }
  }

  private func documentInfo(id: Int64) -> DocumentInfo {
    DocumentInfo(
      document: Document(
        id: nil,
        documentId: id,
        date: Date(timeIntervalSince1970: 1),
        fileName: "draft.txt",
        mimeType: "text/plain",
        size: 12,
        cdnUrl: nil,
        localPath: "draft.txt",
        thumbnailPhotoId: nil
      )
    )
  }

  private func waitForStoredDraft(db: AppDatabase, peer: InlineKit.Peer) async -> Drafts2Snapshot? {
    for _ in 0..<30 {
      let row = try? await db.dbWriter.read { db in
        try Drafts2Row.fetchOne(db, key: peer.toString())
      }
      if let row {
        return row.snapshot(peer: peer)
      }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return nil
  }
}
