import Foundation
import GRDB
import InlineProtocol

public enum MessageEffectiveMediaKind: Hashable, Sendable {
  case photo
  case video
  case document
  case voice
}

public struct MessageEffectiveMediaHit: Equatable, Hashable, Sendable {
  public let message: Message
  public let ref: RichMessageEffectiveMediaRef
  public let source: MessageEffectiveMediaSource

  public init(message: Message, ref: RichMessageEffectiveMediaRef, source: MessageEffectiveMediaSource) {
    self.message = message
    self.ref = ref
    self.source = source
  }
}

public enum MessageEffectiveMediaSource: Hashable, Sendable {
  case root
  case rich
}

public enum MessageEffectiveMediaQuery {
  public static func refs(
    in db: Database,
    chatId: Int64,
    kinds: Set<MessageEffectiveMediaKind>,
    excludingStickers: Bool = false
  ) throws -> [MessageEffectiveMediaHit] {
    guard !kinds.isEmpty else { return [] }

    var hits: [MessageEffectiveMediaHit] = []
    hits.append(contentsOf: try rootRefs(in: db, chatId: chatId, kinds: kinds, excludingStickers: excludingStickers))
    hits.append(contentsOf: try richRefs(in: db, chatId: chatId, kinds: kinds, excludingStickers: excludingStickers))
    return deduped(hits)
  }

  private static func rootRefs(
    in db: Database,
    chatId: Int64,
    kinds: Set<MessageEffectiveMediaKind>,
    excludingStickers: Bool
  ) throws -> [MessageEffectiveMediaHit] {
    let wantsColumnMedia = kinds.contains(.photo) || kinds.contains(.video) || kinds.contains(.document)
    let wantsVoice = kinds.contains(.voice)
    guard wantsColumnMedia || wantsVoice else { return [] }

    var request = Message
      .filter(Message.Columns.chatId == chatId)

    if excludingStickers {
      request = request.filter(Message.Columns.isSticker == false || Message.Columns.isSticker == nil)
    }

    if wantsColumnMedia, wantsVoice {
      request = request.filter(
        Message.Columns.photoId != nil ||
          Message.Columns.videoId != nil ||
          Message.Columns.documentId != nil ||
          Message.Columns.contentPayload != nil
      )
    } else if wantsColumnMedia {
      request = request.filter(
        Message.Columns.photoId != nil ||
          Message.Columns.videoId != nil ||
          Message.Columns.documentId != nil
      )
    } else {
      request = request.filter(Message.Columns.contentPayload != nil)
    }

    let messages = try request
      .order(Message.Columns.date.desc)
      .fetchAll(db)

    var hits: [MessageEffectiveMediaHit] = []
    for message in messages {
      if kinds.contains(.photo), let photoId = message.photoId, photoId > 0 {
        hits.append(MessageEffectiveMediaHit(message: message, ref: .photo(photoId), source: .root))
      }
      if kinds.contains(.video), let videoId = message.videoId, videoId > 0 {
        hits.append(MessageEffectiveMediaHit(message: message, ref: .video(videoId), source: .root))
      }
      if kinds.contains(.document), let documentId = message.documentId, documentId > 0 {
        hits.append(MessageEffectiveMediaHit(message: message, ref: .document(documentId), source: .root))
      }
      if kinds.contains(.voice), let voiceId = message.voiceRemoteId {
        hits.append(MessageEffectiveMediaHit(message: message, ref: .voice(voiceId), source: .root))
      }
    }
    return hits
  }

  private static func richRefs(
    in db: Database,
    chatId: Int64,
    kinds: Set<MessageEffectiveMediaKind>,
    excludingStickers: Bool
  ) throws -> [MessageEffectiveMediaHit] {
    var request = Message
      .filter(Message.Columns.chatId == chatId)
      .filter(Message.Columns.richText != nil)

    if excludingStickers {
      request = request.filter(Message.Columns.isSticker == false || Message.Columns.isSticker == nil)
    }

    let messages = try request
      .order(Message.Columns.date.desc)
      .fetchAll(db)

    var hits: [MessageEffectiveMediaHit] = []
    for message in messages {
      guard let richText = message.richText else { continue }
      for ref in richText.effectiveMediaRefs where kinds.contains(ref.kind) {
        hits.append(MessageEffectiveMediaHit(message: message, ref: ref, source: .rich))
      }
    }
    return hits
  }

  private static func deduped(_ hits: [MessageEffectiveMediaHit]) -> [MessageEffectiveMediaHit] {
    var seen: Set<MessageEffectiveMediaDedupKey> = []
    let sorted = hits.sorted { lhs, rhs in
      if lhs.message.date != rhs.message.date {
        return lhs.message.date > rhs.message.date
      }
      if lhs.message.messageId != rhs.message.messageId {
        return lhs.message.messageId > rhs.message.messageId
      }
      if lhs.ref.sortKey != rhs.ref.sortKey {
        return lhs.ref.sortKey < rhs.ref.sortKey
      }
      return lhs.source.sortValue < rhs.source.sortValue
    }

    return sorted.filter { hit in
      let insert = seen.insert(MessageEffectiveMediaDedupKey(messageId: hit.message.messageId, ref: hit.ref))
      return insert.inserted
    }
  }
}

private struct MessageEffectiveMediaDedupKey: Hashable {
  let messageId: Int64
  let ref: RichMessageEffectiveMediaRef
}

public extension RichMessageEffectiveMediaRef {
  var kind: MessageEffectiveMediaKind {
    switch self {
    case .photo:
      .photo
    case .video:
      .video
    case .document:
      .document
    case .voice:
      .voice
    }
  }

  fileprivate var sortKey: String {
    switch self {
    case let .photo(id):
      "photo:\(id)"
    case let .video(id):
      "video:\(id)"
    case let .document(id):
      "document:\(id)"
    case let .voice(id):
      "voice:\(id)"
    }
  }
}

private extension MessageEffectiveMediaSource {
  var sortValue: Int {
    switch self {
    case .root:
      0
    case .rich:
      1
    }
  }
}
