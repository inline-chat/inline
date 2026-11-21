import Foundation

/// What a chat shows in place of the composer when the viewer can't message
/// its bot. Exists only for a known "no": an unknown answer keeps the composer,
/// and so does a bot that wrote to the viewer lately.
public struct BotNoAccessNotice: Equatable, Sendable {
  public let botUserID: Int64
  /// The owner to ask, when the app knows who it is.
  public let ownerUserID: Int64?
  public let text: String
  /// "Message Mo", when there is an owner to message.
  public let actionTitle: String?

  public static func make(bot: User, access: AgentGrantAccess?, owner: User?) -> BotNoAccessNotice? {
    guard bot.bot == true, let access, access.isUnreachable else { return nil }
    let botName = bot.shortDisplayName
    guard access.ownerUserID > 0, let owner, owner.id == access.ownerUserID else {
      return BotNoAccessNotice(
        botUserID: bot.id,
        ownerUserID: nil,
        text: String(localized: "\(botName) hasn’t been shared with you"),
        actionTitle: nil
      )
    }
    let ownerName = owner.shortDisplayName
    return BotNoAccessNotice(
      botUserID: bot.id,
      ownerUserID: owner.id,
      text: String(localized: "\(ownerName) hasn’t shared \(botName) with you"),
      actionTitle: String(localized: "Message \(ownerName)")
    )
  }
}

public extension OwnedAgentGrants {
  /// "Only you", "Everyone" or "You + 3" (people, spaces and groups added),
  /// for a bot's one-line subtitle in Settings → Bots.
  func compactSharingSummary(openToEveryone: Bool) -> String {
    if openToEveryone { return String(localized: "Everyone") }
    let added = userIDs.count + spaceIDs.count + groupIDs.count
    return added == 0 ? String(localized: "Only you") : String(localized: "You + \(added)")
  }

  /// "Only you", "3 people", "Acme and 2 people", or "Everyone" for the
  /// owner's summary row. `spaceNames` are the granted spaces the app knows.
  func sharedWithSummary(openToEveryone: Bool, spaceNames: [String] = []) -> String {
    if openToEveryone { return String(localized: "Everyone") }
    let people = userIDs.count
    let groups = groupIDs.count
    var parts: [String] = []
    if let first = spaceNames.first {
      parts.append(spaceIDs.count > 1 ? String(localized: "\(first) and \(spaceIDs.count - 1) more") : first)
    } else if !spaceIDs.isEmpty {
      parts.append(spaceIDs.count == 1 ? String(localized: "1 space") : String(localized: "\(spaceIDs.count) spaces"))
    }
    if groups > 0 {
      parts.append(groups == 1 ? String(localized: "1 group") : String(localized: "\(groups) groups"))
    }
    if people > 0 {
      parts.append(people == 1 ? String(localized: "1 person") : String(localized: "\(people) people"))
    }
    if parts.isEmpty { return String(localized: "Only you") }
    return ListFormatter.localizedString(byJoining: parts)
  }
}
