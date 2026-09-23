import Combine
import Foundation
import GRDB

public enum SpaceMemberBadgePolicy {
  public static func isEligible(space: Space, member: Member) -> Bool {
    member.spaceId == space.id && member.canAccessPublicChats &&
      space.isPro && space.photoFileUniqueId != nil && space.photoURL != nil
  }
}

@MainActor
public final class SpaceMemberBadgeViewModel: ObservableObject {
  @Published public private(set) var space: Space?
  private var observation: AnyCancellable?

  public init(db: AppDatabase, userID: Int64, spaceID: Int64) {
    observation = ValueObservation.tracking { db -> Space? in
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
