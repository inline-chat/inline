import Foundation
import InlineProtocol

public enum SpaceJoinReference: Equatable, Sendable {
  case publicHandle(String)
  case inviteToken(String)

  public init?(deepLink: InlineDeepLink) {
    switch deepLink {
    case let .publicSpace(handle):
      self = .publicHandle(handle)
    case let .spaceInvite(token):
      self = .inviteToken(token)
    case .user, .chat, .message:
      return nil
    }
  }
}

public enum SpaceJoinError: Error, LocalizedError {
  case invalidResponse

  public var errorDescription: String? {
    "This invite is invalid, expired, or unavailable."
  }
}

public enum SpaceJoiner {
  public static func join(_ reference: SpaceJoinReference) async throws -> Int64 {
    switch reference {
    case let .publicHandle(handle):
      let result = try await Api.realtime.send(.joinPublicSpace(handle: handle))
      guard case let .joinPublicSpace(response) = result else { throw SpaceJoinError.invalidResponse }
      return response.space.id

    case let .inviteToken(token):
      let result = try await Api.realtime.send(.joinSpaceByInviteToken(token: token))
      guard case let .joinSpaceByInviteToken(response) = result else { throw SpaceJoinError.invalidResponse }
      return response.space.id
    }
  }
}
