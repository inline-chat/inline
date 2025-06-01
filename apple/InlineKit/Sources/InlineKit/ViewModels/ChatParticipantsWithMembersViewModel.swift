import Combine
import GRDB
import Logger
import SwiftUI

/// Chat participants view model that falls back to space members for public threads
public final class ChatParticipantsWithMembersViewModel: ObservableObject {
  @Published public private(set) var participants: [UserInfo] = []

  private var participantsCancellable: AnyCancellable?
  private var spaceMembersCancellable: AnyCancellable?
  private let db: AppDatabase
  private let chatId: Int64
  private let log = Log.scoped("EnhancedChatParticipantsViewModel")

  public init(db: AppDatabase, chatId: Int64) {
    self.db = db
    self.chatId = chatId

    fetchParticipants()
  }

  private func fetchParticipants() {
    log.debug("🔍 Fetching participants for chatId: \(chatId)")

    let chatId = chatId
    let log = log

    participantsCancellable = ValueObservation
      .tracking { db in
        // First, get the chat to check if it's a public thread
        let chat = try Chat.fetchOne(db, id: chatId)

        if let chat, chat.isPublic == true {
          log.debug("🔍 Public thread, fetching space members")
          let spaceMembers = try Member
            .fullMemberQuery()
            .filter(Column("spaceId") == chat.spaceId)
            .fetchAll(db)

          return spaceMembers.map(\.userInfo)
        } else {
          log.debug("🔍 Private thread, fetching chat participants")
          // Get chat participants
          let chatParticipants = try ChatParticipant
            .including(
              required: ChatParticipant.user
                .including(all: User.photos.forKey(UserInfo.CodingKeys.profilePhoto))
            )
            .filter(Column("chatId") == chatId)
            .asRequest(of: UserInfo.self)
            .fetchAll(db)

          return chatParticipants
        }
      }
      .publisher(in: db.dbWriter, scheduling: .immediate)
      .sink(
        receiveCompletion: { [weak self] completion in
          if case let .failure(error) = completion {
            self?.log.error("Failed to get enhanced chat participants: \(error)")
          }
        },
        receiveValue: { [weak self] participants in
          self?.log.debug("🔍 Updated participants: \(participants.count) users")
          self?.participants = participants
        }
      )
  }

  public func refetchParticipants() async {
    log.debug("🔍 Refetching participants...")
    let chatId = chatId

    do {
      // First try to get chat participants
      try await Realtime.shared.invokeWithHandler(
        .getChatParticipants,
        input: .getChatParticipants(.with { $0.chatID = chatId })
      )

      // Also try to get space members if this is a public thread
      let chat = try? await db.reader.read { db in
        try Chat.fetchOne(db, id: chatId)
      }

      if let chat,
         chat.isPublic == true,
         let spaceId = chat.spaceId
      {
        log.debug("🔍 Also fetching space members for public thread, spaceId: \(spaceId)")
        try await Realtime.shared.invokeWithHandler(
          .getSpaceMembers,
          input: .getSpaceMembers(.with { $0.spaceID = spaceId })
        )
      }

    } catch {
      log.error("Failed to refetch enhanced chat participants", error: error)
    }
  }
}
