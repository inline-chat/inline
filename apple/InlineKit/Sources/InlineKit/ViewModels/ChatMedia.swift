import Combine
import GRDB
import InlineProtocol
import Logger
import SwiftUI

public enum MediaKind: Hashable, Sendable {
  case photo(PhotoInfo)
  case video(VideoInfo)
}

public struct MediaMessage: Codable, Equatable, Hashable, FetchableRecord, PersistableRecord, Sendable,
  Identifiable
{
  public var id: Int64 {
    message.messageId
  }

  public var message: Message
  public var photo: PhotoInfo?
  public var video: VideoInfo?

  public enum CodingKeys: String, CodingKey {
    case message
    case photo
    case video
  }

  public init(message: Message, photo: PhotoInfo? = nil, video: VideoInfo? = nil) {
    self.message = message
    self.photo = photo
    self.video = video
  }

  public var kind: MediaKind? {
    if let photo {
      return .photo(photo)
    }
    if let video {
      return .video(video)
    }
    return nil
  }

  public static func queryRequest(excludingStickers: Bool = false) -> QueryInterfaceRequest<MediaMessage> {
    var request = Message
      .filter(sql: "resourceFlags & ? != 0", arguments: [MessageHistoryScope.media.resourceMask.rawValue])

    if excludingStickers {
      request = request.filter(Message.Columns.isSticker == false || Message.Columns.isSticker == nil)
    }

    return request
      .including(
        optional: Message.photo
          .including(all: Photo.sizes.forKey(PhotoInfo.CodingKeys.sizes))
          .forKey(CodingKeys.photo)
      )
      .including(
        optional: Message.video
          .including(
            optional: Video.thumbnail
              .including(all: Photo.sizes.forKey(PhotoInfo.CodingKeys.sizes))
              .forKey(VideoInfo.CodingKeys.thumbnail)
          )
          .forKey(CodingKeys.video)
      )
      .asRequest(of: MediaMessage.self)
  }
}

@MainActor
public final class ChatMediaViewModel: ChatResourceWindow<MediaMessage>, @unchecked Sendable {
  public var mediaMessages: [MediaMessage] {
    rows
  }

  public init(db: AppDatabase, chatId: Int64, peer: Peer, excludeStickerMedia: Bool = false) {
    super.init(
      db: db,
      chatId: chatId,
      peer: peer,
      scope: .media,
      fetchRows: { db, limit in
        try MediaMessage.queryRequest(excludingStickers: excludeStickerMedia)
          .filter(Message.Columns.chatId == chatId)
          .order(Message.Columns.messageId.desc)
          .limit(limit)
          .fetchAll(db)
          .filter { $0.kind != nil }
      },
      messageID: { $0.message.messageId }
    )
  }

  @Published public private(set) var groupedMediaMessages: [MediaMessageGroup] = []

  override public func rowsDidChange() {
    groupedMediaMessages = Self.dayGroups(rows, date: \.message.date, messageID: \.message.messageId)
      .map { MediaMessageGroup(date: $0.date, messages: $0.rows) }
  }
}

public struct MediaMessageGroup {
  public let date: Date
  public let messages: [MediaMessage]
}
