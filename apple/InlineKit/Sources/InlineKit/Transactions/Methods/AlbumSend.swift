import Foundation
import InlineProtocol

/// Holds an album's sends until every item's upload has settled, so its items reach the server
/// back to back (in admission order, through `OutgoingSendOrder`) and recipients see one album
/// instead of photos trickling in with other messages between them.
///
/// The album's uploads start together when its sends are made (`TransactionSendMessage.sends`),
/// outside the transaction actor, and each send waits on those uploads, never on its siblings'
/// transactions: the actor runs only a few transactions at once, so waiting on a sibling that
/// has not started could hold every slot forever. A send joins its own upload when it runs
/// (`SendMessageUploadCoordinator` shares it). A failed or cancelled upload settles too, so one
/// bad item never holds the rest; it sends alone when its retry works. Sends that were never
/// registered (a send recovered after relaunch) pass straight through.
final class AlbumSendBarrier: @unchecked Sendable {
  static let shared = AlbumSendBarrier()

  private let lock = NSLock()
  /// Uploads not yet settled per album.
  private var pending: [Int64: Int] = [:]
  private var albumOf: [String: Int64] = [:]
  private var waiters: [String: CheckedContinuation<Void, Never>] = [:]

  /// Registers an album's sends and starts watching its uploads, which settle the album as
  /// each one finishes, fails or is cancelled.
  func register(groupedId: Int64, transactionIds: [String], uploads: [@Sendable () async -> Void]) {
    guard transactionIds.count > 1 else { return }
    lock.withLock {
      pending[groupedId, default: 0] += uploads.count
      for id in transactionIds {
        albumOf[id] = groupedId
      }
    }
    for upload in uploads {
      Task(priority: .userInitiated) { [self] in
        await upload()
        uploadSettled(groupedId: groupedId)
      }
    }
  }

  private func uploadSettled(groupedId: Int64) {
    let released: [CheckedContinuation<Void, Never>] = lock.withLock {
      guard let count = pending[groupedId] else { return [] }
      guard count <= 1 else {
        pending[groupedId] = count - 1
        return []
      }
      pending[groupedId] = nil
      var released: [CheckedContinuation<Void, Never>] = []
      for (id, album) in albumOf where album == groupedId {
        albumOf[id] = nil
        if let waiter = waiters.removeValue(forKey: id) { released.append(waiter) }
      }
      return released
    }
    released.forEach { $0.resume() }
  }

  /// Forgets a send that ended (sent, failed, rolled back). Idempotent; unknown ids are ignored.
  func settle(transactionId: String) {
    let waiter = lock.withLock {
      albumOf[transactionId] = nil
      return waiters.removeValue(forKey: transactionId)
    }
    waiter?.resume()
  }

  /// Returns once every upload of this send's album has settled, or on cancellation.
  func waitForAlbum(transactionId: String) async {
    await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let ready: Bool = lock.withLock {
          guard !Task.isCancelled, let groupedId = albumOf[transactionId], pending[groupedId] != nil
          else { return true }
          waiters[transactionId] = continuation
          return false
        }
        if ready { continuation.resume() }
      }
    } onCancel: {
      let waiter = lock.withLock { waiters.removeValue(forKey: transactionId) }
      waiter?.resume()
    }
  }

  func isRegistered(transactionId: String) -> Bool {
    lock.withLock { albumOf[transactionId] != nil }
  }
}

public extension TransactionSendMessage {
  /// Photos, videos and files sent together form albums of at most this many.
  static let maxAlbumSize = 10

  /// The sends for a compose with attachments: one per attachment. Neighbouring photos, videos
  /// and files become albums of up to `maxAlbumSize` (a longer run is split into several);
  /// voice notes are sent alone. Within an album the photos and videos go first, then the
  /// files, as the bubble draws them. The text, reply and entities ride on the first send,
  /// which is the album's caption when it starts one.
  ///
  /// Albums are registered with `AlbumSendBarrier` here, so admit every returned send.
  static func sends(
    text: String?,
    peerId: Peer,
    chatId: Int64,
    mediaItems: [FileMediaItem],
    replyToMsgId: Int64? = nil,
    entities: MessageEntities? = nil,
    sendMode: MessageSendMode? = nil
  ) -> [TransactionSendMessage] {
    // The caption goes on whichever item is sent first (a photo moved ahead of a file).
    let first = sendOrder(mediaItems).first
    return sends(
      peerId: peerId,
      chatId: chatId,
      items: mediaItems.enumerated().map { index, media in
        AlbumSendItem(media: media, text: index == first ? text : nil, entities: index == first ? entities : nil)
      },
      replyToMsgId: replyToMsgId,
      sendMode: sendMode
    )
  }

  /// As `sends(text:…)`, with each item's own caption (a picker with per-photo captions). The
  /// reply rides on the first send.
  static func sends(
    peerId: Peer,
    chatId: Int64,
    items: [AlbumSendItem],
    replyToMsgId: Int64? = nil,
    sendMode: MessageSendMode? = nil
  ) -> [TransactionSendMessage] {
    var sends: [TransactionSendMessage] = []
    sends.reserveCapacity(items.count)
    for run in albumSendRuns(items.map(\.media)) {
      let groupedId: Int64? = run.count > 1 ? Int64.random(in: 1 ... Int64.max) : nil
      var ids: [String] = []
      for index in run {
        let item = items[index]
        let send = TransactionSendMessage(
          text: item.text,
          peerId: peerId,
          chatId: chatId,
          mediaItems: [item.media],
          replyToMsgId: sends.isEmpty ? replyToMsgId : nil,
          entities: item.entities,
          sendMode: sendMode,
          groupedId: groupedId
        )
        ids.append(send.id)
        sends.append(send)
      }
      if let groupedId {
        let albumSends = Array(sends.suffix(ids.count))
        AlbumSendBarrier.shared.register(
          groupedId: groupedId,
          transactionIds: ids,
          // Each upload starts now; the send joins it when it runs. Failures surface there.
          uploads: albumSends.map { send in { _ = try? await send.uploadAttachment() } }
        )
      }
    }
    return sends
  }

  /// Indexes of `media` in the order they are sent, by album: `albumRuns`, each run's photos
  /// and videos first, then its files, each in their order.
  static func albumSendRuns(_ media: [FileMediaItem]) -> [[Int]] {
    albumRuns(media.map(\.isAlbumEligible)).map { run in
      run.filter { media[$0].isAlbumMedia } + run.filter { !media[$0].isAlbumMedia }
    }
  }

  /// Indexes of `media` in the order they are sent.
  static func sendOrder(_ media: [FileMediaItem]) -> [Int] {
    albumSendRuns(media).flatMap(\.self)
  }

  /// Index runs in order: consecutive eligible items in runs of at most `maxAlbumSize`, every
  /// other item alone.
  static func albumRuns(_ eligible: [Bool]) -> [[Int]] {
    var runs: [[Int]] = []
    var current: [Int] = []
    for (index, isEligible) in eligible.enumerated() {
      if isEligible, current.count < maxAlbumSize {
        current.append(index)
        continue
      }
      if !current.isEmpty { runs.append(current) }
      current = isEligible ? [index] : []
      if !isEligible { runs.append([index]) }
    }
    if !current.isEmpty { runs.append(current) }
    return runs
  }
}

/// One attachment of a send with its own caption.
public struct AlbumSendItem: Sendable {
  public var media: FileMediaItem
  public var text: String?
  public var entities: MessageEntities?

  public init(media: FileMediaItem, text: String? = nil, entities: MessageEntities? = nil) {
    self.media = media
    self.text = text
    self.entities = entities
  }
}

extension FileMediaItem {
  /// Photos, videos and documents join albums; voice notes are sent alone.
  var isAlbumEligible: Bool {
    switch self {
      case .photo, .video, .document: true
      case .voice: false
    }
  }

  /// Photos and videos: the album's grid. Documents are its file rows.
  var isAlbumMedia: Bool {
    switch self {
      case .photo, .video: true
      case .document, .voice: false
    }
  }
}
