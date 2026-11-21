import Combine
import Foundation
import GRDB

public enum SpaceMemberBadgePolicy {
  public static func isEligible(space: Space, member: Member) -> Bool {
    member.spaceId == space.id && member.canAccessPublicChats &&
      space.isPro && hasBadgePhoto(space)
  }

  /// The Pro spaces whose team plan covers a user: spaces this device knows where they're a full
  /// member, earliest joined first. A future "choose your badge" setting would reorder this list.
  public static func teamPlans(_ db: Database, userID: Int64) throws -> [Space] {
    let memberships = try Member
      .filter(Member.Columns.userId == userID)
      .order(Member.Columns.date.asc, Member.Columns.id.asc)
      .fetchAll(db)
    return try memberships.compactMap { member in
      guard member.canAccessPublicChats, let space = try Space.fetchOne(db, key: member.spaceId),
            space.isPro
      else { return nil }
      return space
    }
  }

  /// The Pro space a user represents outside any space context: the first of their team plans
  /// with a photo to show.
  public static func affiliation(_ db: Database, userID: Int64) throws -> Space? {
    try teamPlans(db, userID: userID).first(where: hasBadgePhoto)
  }

  public static func hasBadgePhoto(_ space: Space) -> Bool {
    space.photoFileUniqueId != nil && space.photoURL != nil
  }
}

@MainActor
public final class SpaceMemberBadgeViewModel: ObservableObject {
  @Published public private(set) var space: Space?
  private var observation: AnyCancellable?

  /// - Parameter spaceID: The space in context. Without one, the user's affiliation badge.
  public init(db: AppDatabase, userID: Int64, spaceID: Int64?) {
    observation = ValueObservation.tracking { db -> Space? in
      guard let spaceID else {
        return try SpaceMemberBadgePolicy.affiliation(db, userID: userID)
      }
      guard let space = try Space.fetchOne(db, key: spaceID),
            let member = try Member.filter(Member.Columns.spaceId == spaceID)
              .filter(Member.Columns.userId == userID).fetchOne(db),
            SpaceMemberBadgePolicy.isEligible(space: space, member: member)
      else { return nil }
      return space
    }
    .publisher(in: db.dbWriter, scheduling: .immediate)
    .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] in self?.space = $0 })
  }
}

/// The signed-in account's team plans, for its plan tag in Settings.
@MainActor
public final class TeamPlansViewModel: ObservableObject {
  @Published public private(set) var spaces: [Space] = []
  private var observation: AnyCancellable?

  public init(db: AppDatabase, userID: Int64) {
    observation = ValueObservation.tracking { db in
      try SpaceMemberBadgePolicy.teamPlans(db, userID: userID)
    }
    .publisher(in: db.dbWriter, scheduling: .immediate)
    .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] in self?.spaces = $0 })
  }
}
