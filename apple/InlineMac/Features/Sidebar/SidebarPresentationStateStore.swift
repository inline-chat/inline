import Foundation

struct SidebarPresentationStateStore {
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func detachedReplyIDs(userID: Int64?) -> Set<ChatListItem.Identifier> {
    identifiers(forKey: key("detachedReplyIDs", userID: userID))
  }

  func setDetachedReplyIDs(
    _ ids: Set<ChatListItem.Identifier>,
    userID: Int64?
  ) {
    setIdentifiers(ids, forKey: key("detachedReplyIDs", userID: userID))
  }

  func collapsedParentIDs(userID: Int64?) -> Set<ChatListItem.Identifier> {
    identifiers(forKey: key("collapsedParentIDs", userID: userID))
  }

  func setCollapsedParentIDs(
    _ ids: Set<ChatListItem.Identifier>,
    userID: Int64?
  ) {
    setIdentifiers(ids, forKey: key("collapsedParentIDs", userID: userID))
  }

  private func identifiers(forKey key: String) -> Set<ChatListItem.Identifier> {
    let values = defaults.array(forKey: key) as? [NSNumber] ?? []
    return Set(values.map { value in
      ChatListItem.Identifier(kind: .thread, rawValue: value.int64Value)
    })
  }

  private func setIdentifiers(
    _ ids: Set<ChatListItem.Identifier>,
    forKey key: String
  ) {
    defaults.set(
      ids.filter { $0.kind == .thread }.map(\.rawValue).sorted(),
      forKey: key
    )
  }

  private func key(_ state: String, userID: Int64?) -> String {
    "experimental.appKitSidebar.\(state).\(userID.map(String.init) ?? "signed-out")"
  }
}
