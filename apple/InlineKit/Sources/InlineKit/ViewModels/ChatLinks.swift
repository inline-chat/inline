import Combine
import GRDB
import Logger
import SwiftUI

public struct LinkMessage: Codable, Equatable, Hashable, FetchableRecord, PersistableRecord, Sendable,
  Identifiable
{
  public var id: Int64 {
    if let id = attachment.id {
      return id
    }
    if let urlPreview {
      return urlPreview.id
    }
    return message.messageId
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

  public static func queryRequest(chatId: Int64) -> QueryInterfaceRequest<LinkMessage> {
    Attachment
      .filter(Column("urlPreviewId") != nil)
      .including(
        required: Attachment.message
          .filter(Message.Columns.chatId == chatId)
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
public final class ChatLinksViewModel: ObservableObject, @unchecked Sendable {
  private let chatId: Int64
  private let db: AppDatabase

  @Published public private(set) var linkMessages: [LinkMessage] = []

  private var cancellable: AnyCancellable?
  private var hasStarted = false

  public init(db: AppDatabase, chatId: Int64) {
    self.db = db
    self.chatId = chatId
    fetchLinkMessages()
  }

  private func fetchLinkMessages() {
    cancellable = ValueObservation
      .tracking { [chatId] db -> [LinkMessage] in
        let previewMessages: [LinkMessage] = try LinkMessage.queryRequest(chatId: chatId)
          .fetchAll(db)
        let previewMessageIds = Set(previewMessages.map { $0.message.messageId })

        let textLinkMessages: [Message] = try Message
          .filter(Message.Columns.chatId == chatId)
          .filter(Message.Columns.hasLink == true)
          .fetchAll(db)

        let fallbackMessages: [LinkMessage] = textLinkMessages.compactMap { message in
          guard !previewMessageIds.contains(message.messageId) else { return nil }
          return Self.fallbackLinkMessage(from: message)
        }

        return previewMessages + fallbackMessages
      }
      .publisher(in: db.dbWriter, scheduling: .immediate)
      .sink(
        receiveCompletion: { [chatId] completion in
          if case let .failure(error) = completion {
            Log.shared.error("Failed to load chat links for chat \(chatId)", error: error)
          }
        },
        receiveValue: { [weak self] (messages: [LinkMessage]) in
          guard let self else { return }
          self.linkMessages = messages.sorted { $0.message.date > $1.message.date }
        }
      )
  }

  private static func fallbackLinkMessage(from message: Message) -> LinkMessage {
    var attachment = Attachment(
      messageId: message.globalId,
      externalTaskId: nil,
      urlPreviewId: nil,
      attachmentId: nil
    )
    attachment.id = fallbackAttachmentId(messageId: message.messageId)
    return LinkMessage(
      attachment: attachment,
      message: message,
      urlPreview: message.detectedLinkPreview
    )
  }

  private static func fallbackAttachmentId(messageId: Int64) -> Int64 {
    let baseId = messageId == 0 ? 1 : messageId
    return baseId > 0 ? -baseId : baseId
  }

  public var groupedLinkMessages: [LinkMessageGroup] {
    let calendar = Calendar.current
    let grouped = Dictionary(grouping: linkMessages) { message in
      calendar.startOfDay(for: message.message.date)
    }

    return grouped.map { date, messages in
      LinkMessageGroup(date: date, messages: messages.sorted { $0.message.date > $1.message.date })
    }.sorted { $0.date > $1.date }
  }

  public func loadInitial() async {
    guard !hasStarted else { return }
    hasStarted = true
  }

  public func loadMoreIfNeeded(currentMessageId: Int64) async {
    _ = currentMessageId
  }
}

public struct LinkMessageGroup {
  public let date: Date
  public let messages: [LinkMessage]
}
