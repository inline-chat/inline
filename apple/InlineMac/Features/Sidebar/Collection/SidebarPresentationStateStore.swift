import Foundation

struct SidebarPresentationStateStore {
  private static let namespace = "sidebar.collection"
  private static let legacyNamespace = "experimental.appKitSidebar"

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func detachedReplyIDs(userID: Int64?) -> Set<ChatListItem.Identifier> {
    identifiers(
      forKey: key("detachedReplyIDs", userID: userID),
      legacyKey: legacyKey("detachedReplyIDs", userID: userID)
    )
  }

  func setDetachedReplyIDs(
    _ ids: Set<ChatListItem.Identifier>,
    userID: Int64?
  ) {
    setIdentifiers(ids, forKey: key("detachedReplyIDs", userID: userID))
  }

  func collapsedParentIDs(userID: Int64?) -> Set<ChatListItem.Identifier> {
    identifiers(
      forKey: key("collapsedParentIDs", userID: userID),
      legacyKey: legacyKey("collapsedParentIDs", userID: userID)
    )
  }

  func setCollapsedParentIDs(
    _ ids: Set<ChatListItem.Identifier>,
    userID: Int64?
  ) {
    setIdentifiers(ids, forKey: key("collapsedParentIDs", userID: userID))
  }

  func collapsedFolderIDs(userID: Int64?) -> Set<Int64> {
    let values = defaults.array(forKey: key("collapsedFolderIDs", userID: userID)) as? [NSNumber]
      ?? []
    return Set(values.map(\.int64Value))
  }

  func setCollapsedFolderIDs(_ ids: Set<Int64>, userID: Int64?) {
    defaults.set(ids.sorted(), forKey: key("collapsedFolderIDs", userID: userID))
  }

  func collapsedSections(
    userID: Int64?
  ) -> Set<SidebarCollectionRow.SectionHeader> {
    let values = defaults.stringArray(
      forKey: key("collapsedSections", userID: userID)
    ) ?? []
    return Set(values.compactMap(SidebarCollectionRow.SectionHeader.init(rawValue:)))
  }

  func setCollapsedSections(
    _ sections: Set<SidebarCollectionRow.SectionHeader>,
    userID: Int64?
  ) {
    defaults.set(
      sections.map(\.rawValue).sorted(),
      forKey: key("collapsedSections", userID: userID)
    )
  }

  private func identifiers(
    forKey key: String,
    legacyKey: String
  ) -> Set<ChatListItem.Identifier> {
    let values = defaults.array(forKey: key) as? [NSNumber]
      ?? defaults.array(forKey: legacyKey) as? [NSNumber]
      ?? []
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
    "\(Self.namespace).\(state).\(userID.map(String.init) ?? "signed-out")"
  }

  private func legacyKey(_ state: String, userID: Int64?) -> String {
    "\(Self.legacyNamespace).\(state).\(userID.map(String.init) ?? "signed-out")"
  }
}
