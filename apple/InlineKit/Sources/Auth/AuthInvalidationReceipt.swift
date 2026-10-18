import CryptoKit
import Foundation

/// The credential authority that received a terminal server revocation. Carry this through
/// asynchronous delivery and revalidate it when admitting logout, never against a later login.
public struct AuthInvalidationReceipt: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
  let mutation: AuthAccountMutationToken
  private let identity: Identity

  private enum Identity: Sendable, Equatable {
    case bearer(Data)
    case native(sessionID: Int64, permanentKeyID: Data, permanentDigest: Data)
  }

  init?(snapshot: AuthSnapshot, mutation: AuthAccountMutationToken) {
    guard snapshot.status.isAuthenticated, snapshot.currentUserId == mutation.userID,
          let identity = Self.identity(for: snapshot)
    else { return nil }
    self.mutation = mutation
    self.identity = identity
  }

  func matches(_ snapshot: AuthSnapshot, generation: UInt64) -> Bool {
    snapshot.status.isAuthenticated && snapshot.currentUserId == mutation.userID &&
      mutation.generation == generation && Self.identity(for: snapshot) == identity
  }

  private static func identity(for snapshot: AuthSnapshot) -> Identity? {
    if case let .authenticated(source) = snapshot.status {
      // A retained bearer still owns the same server session if its optional V3 record is
      // temporarily unavailable or its temporary key/salt rotates.
      return .bearer(Data(SHA256.hash(data: Data(source.token.utf8))))
    }
    guard case .authenticatedV3 = snapshot.status, let credentials = snapshot.inlineProtocol else {
      return nil
    }
    return .native(
      sessionID: credentials.accountSessionId,
      permanentKeyID: Data(credentials.permanent.keyID),
      permanentDigest: Data(SHA256.hash(data: Data(credentials.permanent.key)))
    )
  }

  public var description: String { "AuthInvalidationReceipt(redacted)" }
  public var debugDescription: String { description }
}
