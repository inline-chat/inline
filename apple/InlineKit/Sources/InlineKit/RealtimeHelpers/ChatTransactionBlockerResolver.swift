import Foundation
import GRDB
import RealtimeV2

public struct ChatTransactionBlockerResolver: TransactionBlockerResolver {
  private let database: AppDatabase?

  public init() { database = nil }
  init(database: AppDatabase) { self.database = database }

  public func state(for blocker: TransactionBlocker) async -> TransactionBlockerState {
    switch blocker {
      case let .chatCreated(chatId):
        do {
          return try await (database ?? AppDatabase.shared).reader.read { db in
            guard let chat = try Chat.fetchOne(db, key: chatId) else {
              return .failed
            }

            switch chat.createState {
              case nil:
                return .satisfied
              case .pending:
                return .blocked
              case .failed:
                return .failed
            }
          }
        } catch {
          return .blocked
        }
    }
  }
}
