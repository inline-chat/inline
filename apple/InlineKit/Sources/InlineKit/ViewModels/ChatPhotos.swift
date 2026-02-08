import Combine
import Foundation
import GRDB
import Logger

/// Represents a photo along with its associated message information.
public struct PhotoMessage: Codable, Equatable, Hashable, FetchableRecord, PersistableRecord, Sendable,
  Identifiable
{
  public var id: Int64 { photo.id }
  public var message: Message
  public var photo: PhotoInfo

  public enum CodingKeys: String, CodingKey {
    case message
    case photo
  }

  public init(message: Message, photo: PhotoInfo) {
    self.message = message
    self.photo = photo
  }

  /// Query request for fetching photo messages with all related data
  public static func queryRequest() -> QueryInterfaceRequest<PhotoMessage> {
    Message
      .filter(Column("photoId") != nil)
      .including(
        optional: Message.photo
          .including(all: Photo.sizes.forKey(PhotoInfo.CodingKeys.sizes))
          .forKey(CodingKeys.photo)
      )
      .asRequest(of: PhotoMessage.self)
  }
}

@MainActor
public final class ChatPhotosViewModel: ObservableObject, @unchecked Sendable {
  private let chatId: Int64
  private let db: AppDatabase

  @Published public private(set) var photoMessages: [PhotoMessage] = []

  private var messagesCancellable: AnyCancellable?

  // MARK: – Initialization

  public init(db: AppDatabase, chatId: Int64) {
    self.db = db
    self.chatId = chatId
    fetchPhotoMessages()
  }

  // MARK: – Private helpers

  private func fetchPhotoMessages() {
    db.warnIfInMemoryDatabaseForObservation("ChatPhotosViewModel.photoMessages")
    messagesCancellable = ValueObservation
      .tracking { [chatId] db in
        try PhotoMessage.queryRequest()
          .filter(Column("chatId") == chatId)
          .order(Column("date").desc)
          .fetchAll(db)
      }
      .publisher(in: db.dbWriter, scheduling: .immediate)
      .sink(
        receiveCompletion: { Log.shared.error("Failed to load chat photos \($0)") },
        receiveValue: { [weak self] messages in
          // Remove duplicates (same underlying photo) while keeping order
          var seen: Set<Int64> = []
          let unique = messages.compactMap { message -> PhotoMessage? in
            let insert = seen.insert(message.photo.id)
            return insert.inserted ? message : nil
          }
          self?.photoMessages = unique
        }
      )
  }

  // Group photo messages by date
  public var groupedPhotoMessages: [PhotoMessageGroup] {
    let calendar = Calendar.current
    let grouped = Dictionary(grouping: photoMessages) { photoMessage in
      calendar.startOfDay(for: photoMessage.message.date)
    }

    return grouped.map { date, messages in
      PhotoMessageGroup(date: date, messages: messages.sorted { $0.message.date > $1.message.date })
    }.sorted { $0.date > $1.date }
  }
}

// Helper struct for grouped photo messages
public struct PhotoMessageGroup {
  public let date: Date
  public let messages: [PhotoMessage]
}
