import Foundation
import Logger

/// Handles member management actions that can be reused across views.
@MainActor
public final class SpaceMemberActionsViewModel: ObservableObject {
  @Published public private(set) var deletingMemberIds: Set<Int64> = []

  private let spaceId: Int64
  private let log = Log.scoped("SpaceMemberActions")

  public init(spaceId: Int64) {
    self.spaceId = spaceId
  }

  public func isDeleting(userId: Int64) -> Bool {
    deletingMemberIds.contains(userId)
  }

  public func deleteMember(userId: Int64) async throws {
    guard deletingMemberIds.contains(userId) == false else { return }

    deletingMemberIds.insert(userId)
    defer { deletingMemberIds.remove(userId) }

    let transaction = DeleteMemberTransaction(spaceId: spaceId, userId: userId)

    do {
      _ = try await Api.realtime.send(transaction)
    } catch {
      log.error("Failed to delete member \(userId) in space \(spaceId)", error: error)
      throw error
    }
  }
}
