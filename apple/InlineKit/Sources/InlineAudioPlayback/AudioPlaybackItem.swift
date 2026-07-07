import Foundation

/// Stable identity for a single playable audio item.
///
/// The identity is intentionally message/media based because Inline currently
/// plays cached local media attached to messages. It can still represent generic
/// audio files by using `.audioFile` with the document/media id.
public struct AudioPlaybackItem: Codable, Equatable, Hashable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case voice
    case audioFile
    case music
  }

  public let kind: Kind
  public let chatId: Int64
  public let messageId: Int64
  public let mediaId: Int64

  public init(kind: Kind, chatId: Int64, messageId: Int64, mediaId: Int64) {
    self.kind = kind
    self.chatId = chatId
    self.messageId = messageId
    self.mediaId = mediaId
  }
}
