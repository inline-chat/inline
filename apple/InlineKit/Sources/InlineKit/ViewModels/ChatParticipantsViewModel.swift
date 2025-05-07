import Combine
import GRDB
import Logger
import SwiftUI

public final class ChatParticipantsViewModel: ObservableObject, @unchecked Sendable {
  @Published public private(set) var participants: [UserInfo] = []

  private var participantsCancellable: AnyCancellable?
  private let db: AppDatabase
  private let chatId: Int64

  public init(db: AppDatabase, chatId: Int64) {
    self.db = db
    self.chatId = chatId

    fetchParticipants()
  }

  private func fetchParticipants() {
    participantsCancellable = ValueObservation
      .tracking { db in
        try ChatParticipant
          .including(
            required: ChatParticipant.user
              .including(all: User.photos.forKey(UserInfo.CodingKeys.profilePhoto))
          )
          .filter(Column("chatId") == self.chatId)
          .asRequest(of: UserInfo.self)
          .fetchAll(db)
      }
      .publisher(in: db.dbWriter, scheduling: .immediate)
      .sink(
        receiveCompletion: { Log.shared.error("Failed to get chat participants \($0)") },
        receiveValue: { [weak self] participants in
          self?.participants = participants
        }
      )
  }

  public func refetchParticipants() async {
    do {
      try await Realtime.shared.invokeWithHandler(
        .getChatParticipants,
        input: .getChatParticipants(.with { $0.chatID = chatId })
      )
    } catch {
      Log.shared.error("Failed to refetch chat participants", error: error)
    }
  }
}
