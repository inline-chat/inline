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
    let chatId = chatId
    db.warnIfInMemoryDatabaseForObservation("ChatParticipantsViewModel.participants")
    participantsCancellable = ValueObservation
      .tracking { db in
        try ChatParticipant
          .including(
            required: ChatParticipant.user
              .including(all: User.photos.forKey(UserInfo.CodingKeys.profilePhoto))
          )
          .filter(Column("chatId") == chatId)
          .asRequest(of: UserInfo.self)
          .fetchAll(db)
      }
      .publisher(in: db.dbWriter, scheduling: .immediate)
      .sink(
        receiveCompletion: { completion in
          if case let .failure(error) = completion {
            Log.shared.error("Failed to get chat participants", error: error)
          }
        },
        receiveValue: { [weak self] participants in
          self?.participants = participants
        }
      )
  }

  public func refetchParticipants() async {
    do {
      try await Api.realtime.send(.getChatParticipants(chatID: chatId))
    } catch {
      Log.shared.error("Failed to refetch chat participants", error: error)
    }
  }
}
