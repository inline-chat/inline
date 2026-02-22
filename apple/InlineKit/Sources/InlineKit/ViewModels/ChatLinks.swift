import Combine
import GRDB
import InlineProtocol
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
  private let peer: Peer
  private let db: AppDatabase

  @Published public private(set) var linkMessages: [LinkMessage] = []

  private var cancellable: AnyCancellable?
  private var isLoading = false
  private var hasMore = true
  private var nextOffsetId: Int64?
  private var hasStarted = false

  private let pageSize: Int32 = 50
  private let loadMoreTriggerWindow = 8

  public init(db: AppDatabase, chatId: Int64, peer: Peer) {
    self.db = db
    self.chatId = chatId
    self.peer = peer
    fetchLinkMessages()
  }

  private func fetchLinkMessages() {
    db.warnIfInMemoryDatabaseForObservation("ChatLinksViewModel.links")
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

  private nonisolated static func fallbackLinkMessage(from message: Message) -> LinkMessage {
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

  private nonisolated static func fallbackAttachmentId(messageId: Int64) -> Int64 {
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
    await loadMore(reset: true)
  }

  public func loadMoreIfNeeded(currentMessageId: Int64) async {
    guard Self.shouldLoadMore(
      currentMessageId: currentMessageId,
      loadedMessageIds: linkMessages.map(\.message.messageId),
      triggerWindow: loadMoreTriggerWindow
    ) else { return }
    await loadMore(reset: false)
  }

  nonisolated static func shouldLoadMore(
    currentMessageId: Int64,
    loadedMessageIds: [Int64],
    triggerWindow: Int
  ) -> Bool {
    guard triggerWindow > 0, !loadedMessageIds.isEmpty else { return false }
    let dedupedIds = Array(Set(loadedMessageIds))
    let oldestToNewest = dedupedIds.sorted()
    let triggerCount = min(triggerWindow, oldestToNewest.count)
    return oldestToNewest.prefix(triggerCount).contains(currentMessageId)
  }

  private func loadMore(reset: Bool) async {
    guard !isLoading else { return }

    if reset {
      nextOffsetId = nil
      hasMore = true
    }

    guard hasMore else { return }

    isLoading = true
    defer { isLoading = false }

    do {
      let result = try await Api.realtime.send(
        .searchMessages(
          peer: peer,
          queries: [],
          offsetID: nextOffsetId,
          limit: pageSize,
          filter: .filterLinks
        )
      )

      guard case let .searchMessages(response) = result else {
        Log.shared.error("Unexpected searchMessages response for links in chat \(chatId)")
        return
      }

      guard !response.messages.isEmpty else {
        hasMore = false
        return
      }

      if let lastMessageId = response.messages.last?.id {
        nextOffsetId = lastMessageId
      }

      if response.messages.count < pageSize {
        hasMore = false
      }
    } catch {
      Log.shared.error("Failed to load link messages", error: error)
    }
  }
}

public struct LinkMessageGroup {
  public let date: Date
  public let messages: [LinkMessage]
}
