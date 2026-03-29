import Combine
import GRDB
import Logger
import SwiftUI

@MainActor
public final class ReplyThreadParentViewModel: ObservableObject {
  private struct State {
    let parentChat: Chat?
    let parentUserInfo: UserInfo?
    let parentMessage: FullMessage?
  }

  @Published public private(set) var parentChat: Chat?
  @Published public private(set) var parentUserInfo: UserInfo?
  @Published public private(set) var parentMessage: FullMessage?

  private let chatId: Int64
  private let db: AppDatabase
  private let log = Log.scoped("ReplyThreadParentViewModel")
  private var cancellable: AnyCancellable?

  public init(chatId: Int64, db: AppDatabase? = nil) {
    self.chatId = chatId
    self.db = db ?? AppDatabase.shared
    let initialState = Self.loadState(chatId: chatId, db: self.db, log: log)
    parentChat = initialState.parentChat
    parentUserInfo = initialState.parentUserInfo
    parentMessage = initialState.parentMessage
    observe()
  }

  public var parentTitle: String {
    if let parentUserInfo {
      return parentUserInfo.user.shortDisplayName
    }
    return parentChat?.humanReadableTitle ?? "Parent thread"
  }

  private func observe() {
    let chatId = self.chatId
    db.warnIfInMemoryDatabaseForObservation("ReplyThreadParentViewModel.state")
    cancellable = ValueObservation
      .tracking { db in
        guard let chat = try Chat.fetchOne(db, id: chatId),
              let parentChatId = chat.parentChatId
        else {
          return State(parentChat: nil, parentUserInfo: nil, parentMessage: nil)
        }

        let parentChat = try Chat.fetchOne(db, id: parentChatId)
        let parentUserInfo: UserInfo? = if let parentPeerUserId = parentChat?.peerUserId {
          try User
            .userInfoQuery()
            .filter(User.Columns.id == parentPeerUserId)
            .fetchOne(db)
        } else {
          nil
        }
        let parentMessage: FullMessage? = if let parentMessageId = chat.parentMessageId {
          try FullMessage
            .queryRequest()
            .filter(Message.Columns.chatId == parentChatId && Message.Columns.messageId == parentMessageId)
            .fetchOne(db)
        } else {
          nil
        }

        return State(parentChat: parentChat, parentUserInfo: parentUserInfo, parentMessage: parentMessage)
      }
      .publisher(in: db.reader, scheduling: .immediate)
      .sink(
        receiveCompletion: { [weak self] completion in
          self?.log.error("Failed to observe parent reply-thread context: \(completion)")
        },
        receiveValue: { [weak self] (state: State) in
          self?.parentChat = state.parentChat
          self?.parentUserInfo = state.parentUserInfo
          self?.parentMessage = state.parentMessage
        }
      )
  }

  private static func loadState(chatId: Int64, db: AppDatabase, log: Log) -> State {
    do {
      return try db.reader.read { db in
        guard let chat = try Chat.fetchOne(db, id: chatId),
              let parentChatId = chat.parentChatId
        else {
          return State(parentChat: nil, parentUserInfo: nil, parentMessage: nil)
        }

        let parentChat = try Chat.fetchOne(db, id: parentChatId)
        let parentUserInfo: UserInfo? = if let parentPeerUserId = parentChat?.peerUserId {
          try User
            .userInfoQuery()
            .filter(User.Columns.id == parentPeerUserId)
            .fetchOne(db)
        } else {
          nil
        }
        let parentMessage: FullMessage? = if let parentMessageId = chat.parentMessageId {
          try FullMessage
            .queryRequest()
            .filter(Message.Columns.chatId == parentChatId && Message.Columns.messageId == parentMessageId)
            .fetchOne(db)
        } else {
          nil
        }

        return State(parentChat: parentChat, parentUserInfo: parentUserInfo, parentMessage: parentMessage)
      }
    } catch {
      log.error("Failed to bootstrap parent reply-thread context", error: error)
      return State(parentChat: nil, parentUserInfo: nil, parentMessage: nil)
    }
  }
}
