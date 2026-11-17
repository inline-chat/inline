import Foundation

/// Photos and videos sent together, drawn as one grid in one bubble.
///
/// Each item stays its own message (reply to, forward, save or delete one photo by its message
/// id); an album is how lists show a run of them. View models keep messages flat, and row
/// projections (`MessageAlbums.runs`) turn a run into one row keyed by its oldest item, so an
/// album that fills in as its items arrive keeps its row.
public struct MessageAlbum: Codable, Hashable, Sendable {
  /// Oldest first; at least two.
  public let items: [FullMessage]

  public init?(items: [FullMessage]) {
    guard items.count > 1, let groupedId = items[0].message.groupedId else { return nil }
    self.items = items
    self.groupedId = groupedId
  }

  public let groupedId: Int64

  /// The oldest item: the row's identity, sender, reply and forward header.
  public var lead: FullMessage { items[0] }

  /// The newest item: the album's time.
  public var newest: FullMessage { items[items.count - 1] }

  /// The item whose text is the album's caption: the first with text.
  public var captionItem: FullMessage? {
    items.first { $0.message.text?.isEmpty == false }
  }

  /// Where actions on the bubble go (react, edit the caption, pin) and whose reactions it shows:
  /// the caption's item, else the oldest.
  public var primary: FullMessage { captionItem ?? lead }

  /// Failed if any item failed, else sending if any is still sending.
  public var status: MessageSendingStatus? {
    if items.contains(where: { $0.message.status == .failed }) { return .failed }
    if items.contains(where: { $0.message.status == .sending }) { return .sending }
    return newest.message.status
  }

  /// Server ids of the items, oldest first (temporary ids are negative).
  public var messageIds: [Int64] { items.map(\.message.messageId) }

  public func item(messageId: Int64) -> FullMessage? {
    items.first { $0.message.messageId == messageId }
  }

  /// Whether an item has this stable id (`FullMessage.id`).
  public func contains(stableId: Int64) -> Bool {
    items.contains { $0.id == stableId }
  }

  /// The message a list draws the album's bubble from: the primary item's text, entities,
  /// reactions and acknowledgement; the oldest item's reply and forward header; the newest
  /// item's time and the album's status; and no media of its own (the grid draws the items).
  /// Its stable id (`FullMessage.id`) is the album row's, the oldest item's; its server id is
  /// the primary item's, so actions on the bubble reach that message.
  public var bubbleMessage: FullMessage {
    var bubble = primary
    let lead = lead.message
    bubble.message.globalId = lead.globalId
    bubble.message.repliedToMessageId = lead.repliedToMessageId
    bubble.repliedToMessage = self.lead.repliedToMessage
    bubble.message.forwardFromPeerUserId = lead.forwardFromPeerUserId
    bubble.message.forwardFromPeerThreadId = lead.forwardFromPeerThreadId
    bubble.message.forwardFromMessageId = lead.forwardFromMessageId
    bubble.message.forwardFromUserId = lead.forwardFromUserId
    bubble.forwardFromUserInfo = self.lead.forwardFromUserInfo
    bubble.forwardFromPeerUserInfo = self.lead.forwardFromPeerUserInfo
    bubble.forwardFromChatInfo = self.lead.forwardFromChatInfo
    bubble.message.date = newest.message.date
    bubble.message.status = status
    bubble.message.photoId = nil
    bubble.message.videoId = nil
    bubble.message.documentId = nil
    bubble.photoInfo = nil
    bubble.videoInfo = nil
    bubble.documentInfo = nil
    bubble.file = nil
    return bubble
  }
}

public enum MessageAlbums {
  /// The most items one album draws; a longer run (only from a misbehaving sender) splits.
  public static let maxSize = 10

  /// Whether a message can be drawn as part of an album: a photo or video, not a sticker.
  public static func isEligible(_ message: FullMessage) -> Bool {
    let model = message.message
    guard model.groupedId != nil, model.isSticker != true, !model.isServiceMessage else { return false }
    return message.photoInfo != nil || message.videoInfo != nil
  }

  /// `later` directly follows `earlier` in the same album: same sender, same album id.
  public static func joins(_ earlier: FullMessage, _ later: FullMessage) -> Bool {
    guard let groupedId = earlier.message.groupedId, later.message.groupedId == groupedId,
          earlier.message.fromId == later.message.fromId, earlier.message.chatId == later.message.chatId
    else { return false }
    return isEligible(earlier) && isEligible(later)
  }

  /// Splits a window, in timeline order (oldest first), into runs that each make one row: an
  /// album (two or more items) or a single message. Covers every index once, in order. O(n).
  public static func runs(in messages: [FullMessage]) -> [Range<Int>] {
    var runs: [Range<Int>] = []
    runs.reserveCapacity(messages.count)
    var start = 0
    for index in messages.indices.dropFirst() {
      let joinsRun = index - start < maxSize && joins(messages[index - 1], messages[index])
      if !joinsRun {
        runs.append(start ..< index)
        start = index
      }
    }
    if !messages.isEmpty { runs.append(start ..< messages.count) }
    return runs
  }

  /// One entry per row: a single message, or an album led by its oldest item.
  public enum Row: Equatable, Sendable {
    case message(FullMessage)
    case album(MessageAlbum)

    /// The message the row is keyed and grouped by.
    public var lead: FullMessage {
      switch self {
        case let .message(message): message
        case let .album(album): album.lead
      }
    }

    /// The newest message in the row (read marking, the row's time).
    public var newest: FullMessage {
      switch self {
        case let .message(message): message
        case let .album(album): album.newest
      }
    }

    public var album: MessageAlbum? {
      if case let .album(album) = self { album } else { nil }
    }
  }

  /// `messages` (timeline order) as rows.
  public static func rows(in messages: [FullMessage]) -> [Row] {
    runs(in: messages).map { run in
      if run.count > 1, let album = MessageAlbum(items: Array(messages[run])) {
        .album(album)
      } else {
        .message(messages[run.lowerBound])
      }
    }
  }
}
