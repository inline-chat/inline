import Combine
import GRDB
import InlineProtocol
import Logger
import SwiftUI

public struct LinkMessage: Codable, Equatable, Hashable, FetchableRecord, PersistableRecord, Sendable,
  Identifiable
{
  public var id: Int64 {
    message.messageId
  }

  public var attachment: Attachment
  public var message: Message
  public var urlPreview: UrlPreview?
  public var photoInfo: PhotoInfo?

  public enum CodingKeys: String, CodingKey {
    case attachment
    case message
    case urlPreview
    case photoInfo
  }

  public init(
    attachment: Attachment,
    message: Message,
    urlPreview: UrlPreview? = nil,
    photoInfo: PhotoInfo? = nil
  ) {
    self.attachment = attachment
    self.message = message
    self.urlPreview = urlPreview
    self.photoInfo = photoInfo
  }

  public static func queryRequest(chatId: Int64, messageIds: Set<Int64>? = nil) -> QueryInterfaceRequest<LinkMessage> {
    var messages = Attachment.message.filter(Message.Columns.chatId == chatId)
    if let messageIds {
      messages = messages.filter(messageIds.contains(Message.Columns.messageId))
    }
    return Attachment
      .filter(Column("urlPreviewId") != nil)
      .including(
        required: messages
          .forKey(CodingKeys.message)
      )
      .including(
        optional: Attachment.urlPreview
          .including(
            optional: UrlPreview.photo
              .forKey(CodingKeys.photoInfo)
              .including(all: Photo.sizes.forKey(PhotoInfo.CodingKeys.sizes))
          )
          .forKey(CodingKeys.urlPreview)
      )
      .asRequest(of: LinkMessage.self)
  }
}

@MainActor
public final class ChatLinksViewModel: ChatResourceWindow<LinkMessage>, @unchecked Sendable {
  public var linkMessages: [LinkMessage] {
    rows
  }

  public init(db: AppDatabase, chatId: Int64, peer: Peer) {
    super.init(
      db: db,
      chatId: chatId,
      peer: peer,
      scope: .links,
      fetchRows: { db, limit in
        let messages = try Message.filter(Message.Columns.chatId == chatId)
          .filter(sql: "resourceFlags & ? != 0", arguments: [MessageHistoryScope.links.resourceMask.rawValue])
          .order(Message.Columns.messageId.desc)
          .limit(limit)
          .fetchAll(db)
        let ids = Set(messages.map(\.messageId))
        let previews = try LinkMessage.queryRequest(chatId: chatId, messageIds: ids)
          .fetchAll(db)
        let byMessage = Dictionary(grouping: previews) { $0.message.messageId }
        return messages.map { message in
          if let preview = byMessage[message.messageId]?.first {
            return preview
          }
          let attachment = Attachment(
            messageId: message.globalId,
            externalTaskId: nil,
            urlPreviewId: nil,
            attachmentId: nil
          )
          return LinkMessage(attachment: attachment, message: message, urlPreview: message.detectedLinkPreview)
        }
      },
      messageID: { $0.message.messageId }
    )
  }

  @Published public private(set) var groupedLinkMessages: [LinkMessageGroup] = []

  override public func rowsDidChange() {
    groupedLinkMessages = Dictionary(grouping: rows) { Calendar.current.startOfDay(for: $0.message.date) }
      .map { LinkMessageGroup(date: $0.key, messages: $0.value.sorted { lhs, rhs in
        if lhs.message.date != rhs.message.date {
          return lhs.message.date > rhs.message.date
        }
        return lhs.message.messageId > rhs.message.messageId
      }) }
      .sorted { $0.date > $1.date }
  }
}

public struct LinkMessageGroup {
  public let date: Date
  public let messages: [LinkMessage]
}
