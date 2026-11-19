import Foundation
import InlineProtocol
import Testing
@testable import InlineKit

@Suite("Message albums")
struct MessageAlbumsTests {
  private let start = Date(timeIntervalSince1970: 1_800_000_000)

  private func photo(_ id: Int64) -> PhotoInfo {
    PhotoInfo(photo: Photo(id: id, photoId: id, format: .jpeg))
  }

  private func documentInfo(_ id: Int64, name: String = "a.pdf") -> DocumentInfo {
    DocumentInfo(document: Document(
      id: id, documentId: id, date: start, fileName: name, mimeType: "application/pdf", size: 1, localPath: name
    ))
  }

  private func file(_ id: Int64, from: Int64 = 1, group: Int64? = nil, text: String? = nil) -> FullMessage {
    var full = message(id, from: from, group: group, text: text, media: false)
    full.documentInfo = documentInfo(id)
    return full
  }

  private func message(
    _ id: Int64, from: Int64 = 1, group: Int64? = nil, text: String? = nil, media: Bool = true,
    status: MessageSendingStatus? = nil, sticker: Bool = false
  ) -> FullMessage {
    var message = Message(
      messageId: id, fromId: from, date: start.addingTimeInterval(TimeInterval(id)), text: text,
      peerUserId: nil, peerThreadId: 1, chatId: 1, status: status, isSticker: sticker, groupedId: group
    )
    message.globalId = id + 1000
    var full = FullMessage(senderInfo: nil, message: message, reactions: [], repliedToMessage: nil, attachments: [])
    if media { full.photoInfo = photo(id) }
    return full
  }

  private func shape(_ rows: [MessageAlbums.Row]) -> [[Int64]] {
    rows.map { row in
      switch row {
        case let .message(message): [message.message.messageId]
        case let .album(album): album.messageIds
      }
    }
  }

  @Test("consecutive photos from one sender with one id are one row; anything else breaks the run")
  func runs() {
    let rows = MessageAlbums.rows(in: [
      message(1, group: 7), message(2, group: 7), message(3, group: 7),
      message(4, from: 2, group: 7), // another sender, same id
      message(5, group: 8), // a lone member
      message(6, group: 9), message(7, group: 9, media: false), // text can't join
      message(8), message(9, group: 10), message(10, group: 10, sticker: true),
    ])
    #expect(shape(rows) == [[1, 2, 3], [4], [5], [6], [7], [8], [9], [10]])
  }

  @Test("files join albums with photos and videos; the grid takes the media, the rows the files")
  func files() throws {
    let rows = MessageAlbums.rows(in: [
      file(1, group: 7), message(2, group: 7), file(3, group: 7, text: "notes"), message(4, group: 7),
      file(5, group: 8), file(6, group: 8),
      file(7, from: 2, group: 8), // another sender
      file(8), // no album id
    ])
    #expect(shape(rows) == [[1, 2, 3, 4], [5, 6], [7], [8]])
    let mixed = try #require(rows[0].album)
    #expect(mixed.mediaItems.map(\.message.messageId) == [2, 4])
    #expect(mixed.fileItems.map(\.message.messageId) == [1, 3])
    #expect(mixed.hasMedia && mixed.hasFiles)
    #expect(mixed.captionItem?.message.messageId == 3)
    let files = try #require(rows[1].album)
    #expect(!files.hasMedia && files.hasFiles)
    #expect(files.bubbleMessage.documentInfo == nil)
  }

  @Test("a run longer than ten splits")
  func maxSize() {
    let rows = MessageAlbums.rows(in: (1 ... 12).map { message($0, group: 3) })
    #expect(shape(rows) == [Array(1 ... 10), [11, 12]])
  }

  @Test("an album's caption, primary item, status and time")
  func derived() throws {
    let album = try #require(MessageAlbum(items: [
      message(1, group: 4, status: .sent), message(2, group: 4, text: "trip", status: .sending),
      message(3, group: 4, status: .sent),
    ]))
    #expect(album.lead.message.messageId == 1)
    #expect(album.captionItem?.message.messageId == 2)
    #expect(album.primary.message.messageId == 2)
    #expect(album.newest.message.messageId == 3)
    #expect(album.status == .sending)

    let failed = try #require(MessageAlbum(items: [message(1, group: 4, status: .failed), message(2, group: 4)]))
    #expect(failed.status == .failed)
    #expect(failed.primary.message.messageId == 1)
    #expect(MessageAlbum(items: [message(1, group: 4)]) == nil)
  }

  @Test("a photo between photos of other albums is its own row")
  func empty() {
    #expect(MessageAlbums.rows(in: []).isEmpty)
    #expect(shape(MessageAlbums.rows(in: [message(1, group: 1)])) == [[1]])
  }

  @Test("album send runs: neighbouring eligible items, at most ten; others alone")
  func sendRuns() {
    let runs = TransactionSendMessage.albumRuns([true, true, false, true, true, true] + Array(repeating: true, count: 11))
    #expect(runs == [[0, 1], [2], [3, 4, 5, 6, 7, 8, 9, 10, 11, 12], [13, 14, 15, 16]])
    #expect(TransactionSendMessage.albumRuns([false, false]) == [[0], [1]])
    #expect(TransactionSendMessage.albumRuns([]).isEmpty)
  }

  @Test("compose sends: one album id per run, caption and reply on the first send")
  func composeSends() {
    let photos: [FileMediaItem] = (1 ... 3).map { .photo(photo($0)) }
    let sends = TransactionSendMessage.sends(
      text: "hello", peerId: .thread(id: 1), chatId: 1,
      mediaItems: photos + [.document(documentInfo(-9))], replyToMsgId: 5
    )
    #expect(sends.count == 4)
    #expect(sends.map(\.text) == ["hello", nil, nil, nil])
    #expect(sends.map(\.replyToMsgId) == [5, nil, nil, nil])
    let albumId = sends[0].groupedId
    #expect(albumId != nil)
    #expect(sends.allSatisfy { $0.groupedId == albumId })
    // Each send is a millisecond after the one before, so stored rows keep their order.
    let milliseconds = sends.map { Int64(($0.date.timeIntervalSince1970 * 1_000).rounded(.down)) }
    #expect(zip(milliseconds, milliseconds.dropFirst()).allSatisfy { $0 < $1 })
    #expect(AlbumSendBarrier.shared.isRegistered(transactionId: sends[0].id))
    for send in sends {
      AlbumSendBarrier.shared.settle(transactionId: send.id)
    }
    #expect(!AlbumSendBarrier.shared.isRegistered(transactionId: sends[0].id))
  }

  @Test("compose sends: photos and videos go ahead of files, the caption on the first send; voice alone")
  func composeSendOrder() {
    let media: [FileMediaItem] = [
      .document(documentInfo(-1, name: "a.pdf")), .photo(photo(2)), .document(documentInfo(-3, name: "b.zip")),
      .photo(photo(4)), .voice(Client_MessageVoiceContent()),
    ]
    #expect(TransactionSendMessage.albumSendRuns(media) == [[1, 3, 0, 2], [4]])
    let sends = TransactionSendMessage.sends(text: "look", peerId: .thread(id: 1), chatId: 1, mediaItems: media)
    #expect(sends.map(\.text) == ["look", nil, nil, nil, nil])
    #expect(sends.map { $0.attachments.first?.media.isAlbumMedia } == [true, true, false, false, false])
    #expect(sends[0].groupedId != nil && sends[3].groupedId == sends[0].groupedId)
    #expect(sends[4].groupedId == nil)
    for send in sends {
      AlbumSendBarrier.shared.settle(transactionId: send.id)
    }
  }

  /// An upload that finishes when `open` is called.
  private func gatedUpload() -> (upload: @Sendable () async -> Void, open: () -> Void) {
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    return ({ for await _ in stream { return } }, { continuation.yield(); continuation.finish() })
  }

  @Test("the barrier releases an album's items once every upload settled, without waiting on sends")
  func barrier() async {
    let barrier = AlbumSendBarrier()
    let second = gatedUpload()
    let third = gatedUpload()
    barrier.register(groupedId: 1, transactionIds: ["a", "b", "c"], uploads: [{}, second.upload, third.upload])
    let released = ReleaseRecorder()
    let waiter = Task {
      await barrier.waitForAlbum(transactionId: "a")
      await released.mark()
    }
    try? await Task.sleep(for: .milliseconds(30))
    #expect(await released.value == false)
    second.open()
    try? await Task.sleep(for: .milliseconds(30))
    #expect(await released.value == false)
    // "c" never runs as a transaction (the actor's slots are full); its upload settling is enough.
    third.open()
    await waiter.value
    #expect(await released.value)

    // Settled albums, ended sends and unregistered sends pass straight through.
    await barrier.waitForAlbum(transactionId: "b")
    await barrier.waitForAlbum(transactionId: "unknown")
  }

  @Test("a cancelled wait returns, and an ended send no longer waits")
  func barrierCancellation() async {
    let barrier = AlbumSendBarrier()
    let gate = gatedUpload()
    barrier.register(groupedId: 2, transactionIds: ["a", "b"], uploads: [gate.upload, {}])
    let waiter = Task { await barrier.waitForAlbum(transactionId: "a") }
    try? await Task.sleep(for: .milliseconds(20))
    waiter.cancel()
    await waiter.value
    barrier.settle(transactionId: "b")
    await barrier.waitForAlbum(transactionId: "b")
    gate.open()
  }

  @Test("the album id comes from the protocol and survives a send's transaction encoding")
  func persistence() throws {
    var proto = InlineProtocol.Message()
    proto.id = 3
    proto.fromID = 1
    proto.chatID = 1
    proto.peerID = .with { $0.chat = .with { $0.chatID = 1 } }
    proto.groupedID = 99
    #expect(Message(from: proto).groupedId == 99)
    proto.groupedID = 0
    #expect(Message(from: proto).groupedId == nil)

    let send = TransactionSendMessage(text: nil, peerId: .thread(id: 1), chatId: 1, groupedId: 42)
    let decoded = try JSONDecoder().decode(TransactionSendMessage.self, from: JSONEncoder().encode(send))
    #expect(decoded.groupedId == 42)
  }
}

private actor ReleaseRecorder {
  var value = false
  func mark() { value = true }
}
