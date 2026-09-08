import Foundation

/// Stores only navigation coordinates, scoped to the signed-in account and chat.
/// UserDefaults owns disk persistence; serialization and access stay off MainActor.
public actor MessageListPositionStore {
  public static let shared = MessageListPositionStore()
  private let defaults: UserDefaults

  public init(suiteName: String? = nil) {
    defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
  }

  private var admittedCheckpoints: [String: UInt64] = [:]

  public func load(accountID: Int64, chatID: Int64) -> MessageListInitialPosition? {
    guard accountID > 0, chatID > 0,
          let data = defaults.data(forKey: key(accountID: accountID, chatID: chatID))
    else { return nil }
    return try? JSONDecoder().decode(MessageListInitialPosition.self, from: data)
  }

  public func save(_ position: MessageListInitialPosition, accountID: Int64, chatID: Int64, issuedAt: UInt64) {
    guard accountID > 0, chatID > 0, let data = try? JSONEncoder().encode(position) else { return }
    let key = key(accountID: accountID, chatID: chatID)
    guard issuedAt >= admittedCheckpoints[key, default: 0] else { return }
    admittedCheckpoints[key] = issuedAt
    defaults.set(data, forKey: key)
  }

  private func key(accountID: Int64, chatID: Int64) -> String {
    "experimental.macMessageListV2.position.\(accountID).\(chatID)"
  }
}
