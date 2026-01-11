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
  public var id: Int64 { message.messageId }
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

  public static func queryRequest() -> QueryInterfaceRequest<MediaMessage> {
    Message
      .filter(Message.Columns.photoId != nil || Message.Columns.videoId != nil)
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

private enum MediaKey: Hashable {
  case photo(Int64)
  case video(Int64)
}

@MainActor
public final class ChatMediaViewModel: ObservableObject, @unchecked Sendable {
  private let chatId: Int64
  private let peer: Peer
  private let db: AppDatabase

  @Published public private(set) var mediaMessages: [MediaMessage] = []

  private var messagesCancellable: AnyCancellable?
  private var isLoading = false
  private var hasMorePhotos = true
  private var hasMoreVideos = true
  private var nextPhotoOffsetId: Int64?
  private var nextVideoOffsetId: Int64?
  private var hasStarted = false

  private let pageSize: Int32 = 50

  public init(db: AppDatabase, chatId: Int64, peer: Peer) {
    self.db = db
    self.chatId = chatId
    self.peer = peer
    fetchMediaMessages()
  }

  private func fetchMediaMessages() {
    messagesCancellable = ValueObservation
      .tracking { [chatId] db in
        try MediaMessage.queryRequest()
          .filter(Column("chatId") == chatId)
          .order(Column("date").desc)
          .fetchAll(db)
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
          var seen: Set<MediaKey> = []
          let unique = messages.compactMap { message -> MediaMessage? in
            guard let key = message.mediaKey else { return nil }
            let insert = seen.insert(key)
            return insert.inserted ? message : nil
          }
          Log.shared.debug(
            "Loaded chat media for chat \(self.chatId): raw=\(messages.count) unique=\(unique.count)"
          )
          self.mediaMessages = unique
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
    guard let lastMessageId = mediaMessages.last?.message.id else { return }
    guard currentMessageId == lastMessageId else { return }
    await loadMore(reset: false)
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
