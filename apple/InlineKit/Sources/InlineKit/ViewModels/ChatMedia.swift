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
  public var id: String {
    mediaKey?.id ?? "message:\(message.messageId)"
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

  fileprivate var mediaKey: MediaKey? {
    if let photo {
      return .photo(photo.id)
    }
    if let video {
      return .video(video.id)
    }
    return nil
  }

  public static func queryRequest(excludingStickers: Bool = false) -> QueryInterfaceRequest<MediaMessage> {
    var request = Message
      .filter(Message.Columns.photoId != nil || Message.Columns.videoId != nil)

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

  static func effectiveMessages(
    in db: Database,
    chatId: Int64,
    excludingStickers: Bool = false
  ) throws -> [MediaMessage] {
    let hits = try MessageEffectiveMediaQuery.refs(
      in: db,
      chatId: chatId,
      kinds: [.photo, .video],
      excludingStickers: excludingStickers
    )

    var messages: [MediaMessage] = []
    for hit in hits {
      switch hit.ref {
      case let .photo(photoId):
        if let photo = try photoInfo(in: db, photoId: photoId) {
          messages.append(MediaMessage(message: hit.message, photo: photo))
        }
      case let .video(videoId):
        if let video = try videoInfo(in: db, videoId: videoId) {
          messages.append(MediaMessage(message: hit.message, video: video))
        }
      case .document, .voice:
        break
      }
    }

    return deduped(messages)
  }

  private static func deduped(_ messages: [MediaMessage]) -> [MediaMessage] {
    var seen: Set<MediaKey> = []
    let sorted = messages.sorted { lhs, rhs in
      if lhs.message.date != rhs.message.date {
        return lhs.message.date > rhs.message.date
      }
      if lhs.message.messageId != rhs.message.messageId {
        return lhs.message.messageId > rhs.message.messageId
      }
      return lhs.id < rhs.id
    }

    return sorted.compactMap { message -> MediaMessage? in
      guard let key = message.mediaKey else { return nil }
      let insert = seen.insert(key)
      return insert.inserted ? message : nil
    }
  }

  private static func photoInfo(in db: Database, photoId: Int64) throws -> PhotoInfo? {
    try Photo
      .filter(Photo.Columns.photoId == photoId)
      .including(all: Photo.sizes.forKey(PhotoInfo.CodingKeys.sizes))
      .asRequest(of: PhotoInfo.self)
      .fetchOne(db)
  }

  private static func videoInfo(in db: Database, videoId: Int64) throws -> VideoInfo? {
    try Video
      .filter(Video.Columns.videoId == videoId)
      .including(
        optional: Video.thumbnail
          .including(all: Photo.sizes.forKey(PhotoInfo.CodingKeys.sizes))
          .forKey(VideoInfo.CodingKeys.thumbnail)
      )
      .asRequest(of: VideoInfo.self)
      .fetchOne(db)
  }
}

private enum MediaKey: Hashable {
  case photo(Int64)
  case video(Int64)

  var id: String {
    switch self {
    case let .photo(value):
      return "photo:\(value)"
    case let .video(value):
      return "video:\(value)"
    }
  }
}

@MainActor
public final class ChatMediaViewModel: ObservableObject, @unchecked Sendable {
  private let chatId: Int64
  private let peer: Peer
  private let db: AppDatabase
  private let excludeStickerMedia: Bool

  @Published public private(set) var mediaMessages: [MediaMessage] = []

  private var messagesCancellable: AnyCancellable?
  private var isLoading = false
  private var hasMorePhotos = true
  private var hasMoreVideos = true
  private var nextPhotoOffsetId: Int64?
  private var nextVideoOffsetId: Int64?
  private var hasStarted = false

  private let pageSize: Int32 = 50
  private let loadMoreTriggerWindow = 8

  public init(db: AppDatabase, chatId: Int64, peer: Peer, excludeStickerMedia: Bool = false) {
    self.db = db
    self.chatId = chatId
    self.peer = peer
    self.excludeStickerMedia = excludeStickerMedia
    fetchMediaMessages()
  }

  private func fetchMediaMessages() {
    db.warnIfInMemoryDatabaseForObservation("ChatMediaViewModel.mediaMessages")
    messagesCancellable = ValueObservation
      .tracking { [chatId] db in
        try MediaMessage.effectiveMessages(
          in: db,
          chatId: chatId,
          excludingStickers: self.excludeStickerMedia
        )
      }
      .publisher(in: db.dbWriter, scheduling: .immediate)
      .sink(
        receiveCompletion: { [chatId] completion in
          if case let .failure(error) = completion {
            Log.shared.error("Failed to load chat media for chat \(chatId)", error: error)
          }
        },
        receiveValue: { [weak self] messages in
          guard let self else { return }
          Log.shared.debug(
            "Loaded chat media for chat \(self.chatId): count=\(messages.count)"
          )
          self.mediaMessages = messages
        }
      )
  }

  public var groupedMediaMessages: [MediaMessageGroup] {
    let calendar = Calendar.current
    let grouped = Dictionary(grouping: mediaMessages) { message in
      calendar.startOfDay(for: message.message.date)
    }

    return grouped.map { date, messages in
      MediaMessageGroup(date: date, messages: messages.sorted { $0.message.date > $1.message.date })
    }.sorted { $0.date > $1.date }
  }

  // MARK: - Remote Fetching

  public func loadInitial() async {
    guard !hasStarted else { return }
    hasStarted = true
    await loadMore(reset: true)
  }

  public func loadMoreIfNeeded(currentMessageId: Int64) async {
    guard Self.shouldLoadMore(
      currentMessageId: currentMessageId,
      loadedMessageIds: mediaMessages.map(\.message.messageId),
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
      nextPhotoOffsetId = nil
      nextVideoOffsetId = nil
      hasMorePhotos = true
      hasMoreVideos = true
    }

    guard hasMorePhotos || hasMoreVideos else { return }

    isLoading = true
    defer { isLoading = false }

    if hasMorePhotos {
      do {
        let result = try await Api.realtime.send(
          .searchMessages(
            peer: peer,
            queries: [],
            offsetID: nextPhotoOffsetId,
            limit: pageSize,
            filter: .filterPhotos
          )
        )

        guard case let .searchMessages(response) = result else {
          Log.shared.error("Unexpected searchMessages response for photos in chat \(chatId)")
          return
        }

        guard !response.messages.isEmpty else {
          Log.shared.debug("No more photo messages for chat \(chatId)")
          hasMorePhotos = false
          return
        }

        Log.shared.debug("Loaded \(response.messages.count) photo messages for chat \(chatId)")
        if let lastMessageId = response.messages.last?.id {
          nextPhotoOffsetId = lastMessageId
        }

        if response.messages.count < pageSize {
          hasMorePhotos = false
        }
      } catch {
        Log.shared.error("Failed to load photo messages", error: error)
      }
    }

    if hasMoreVideos {
      do {
        let result = try await Api.realtime.send(
          .searchMessages(
            peer: peer,
            queries: [],
            offsetID: nextVideoOffsetId,
            limit: pageSize,
            filter: .filterVideos
          )
        )

        guard case let .searchMessages(response) = result else {
          Log.shared.error("Unexpected searchMessages response for videos in chat \(chatId)")
          return
        }

        guard !response.messages.isEmpty else {
          Log.shared.debug("No more video messages for chat \(chatId)")
          hasMoreVideos = false
          return
        }

        Log.shared.debug("Loaded \(response.messages.count) video messages for chat \(chatId)")
        if let lastMessageId = response.messages.last?.id {
          nextVideoOffsetId = lastMessageId
        }

        if response.messages.count < pageSize {
          hasMoreVideos = false
        }
      } catch {
        Log.shared.error("Failed to load video messages", error: error)
      }
    }
  }
}

public struct MediaMessageGroup {
  public let date: Date
  public let messages: [MediaMessage]
}
