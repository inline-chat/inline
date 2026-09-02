import Foundation
import GRDB
import InlineKit

@MainActor
enum GettingStartedActions {
  static func openFounderDM(using dependencies: AppDependencies) async throws {
    let localUsers = try await InviteDirectory.localUsers(
      query: "mo",
      database: dependencies.database
    )
    let founder = exactFounder(in: localUsers)

    let resolvedFounder: UserInfo
    if let founder {
      resolvedFounder = founder
    } else {
      let remoteUsers = try await InviteDirectory.remoteUsers(
        query: "mo",
        realtime: dependencies.realtimeV2,
        database: dependencies.database
      )
      guard let remoteFounder = exactFounder(in: remoteUsers) else {
        throw GettingStartedActionError.founderNotFound
      }
      resolvedFounder = remoteFounder
    }

    let peer = Peer.user(id: resolvedFounder.id)
    let hasDialog = try await dependencies.database.reader.read { db in
      try Dialog.fetchOne(db, id: Dialog.getDialogId(peerUserId: resolvedFounder.id)) != nil
    }
    if hasDialog == false {
      _ = try await dependencies.data.createPrivateChat(userId: resolvedFounder.id)
    }
    _ = try await dependencies.realtimeV2.send(.updateDialogOpen(peerId: peer, open: true))
    dependencies.requestOpenChat(peer: peer)
  }

  static func joinCommunity(using dependencies: AppDependencies) async throws -> Int64 {
    let result = try await dependencies.realtimeV2.send(.joinPublicSpace(handle: "townhall"))
    guard case let .joinPublicSpace(response) = result, response.space.id > 0 else {
      throw GettingStartedActionError.invalidResponse
    }
    return response.space.id
  }

  private static func exactFounder(in users: [UserInfo]) -> UserInfo? {
    users.first { userInfo in
      userInfo.user.username?.caseInsensitiveCompare("mo") == .orderedSame
    }
  }
}

private enum GettingStartedActionError: Error {
  case founderNotFound
  case invalidResponse
}
