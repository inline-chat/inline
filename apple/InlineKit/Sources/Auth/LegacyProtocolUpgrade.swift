import CryptoKit
import Foundation
import InlineProtocol

/// Additive migration state. The original bearer remains the account authority throughout
/// rollout, including for older builds that do not know this Keychain item exists.
struct LegacyProtocolUpgrade: Codable, Sendable {
  var version = 1
  let userID: Int64
  let sourceDigest: Data
  var permanent: InlineProtocolAuthorization
  var credentials: InlineProtocolSessionCredentials?

  init(source: AuthCredentials, permanent: InlineProtocolAuthorization) throws {
    userID = source.userId
    sourceDigest = Self.digest(source.token)
    self.permanent = permanent
    try validate()
  }

  func matches(_ source: AuthCredentials) -> Bool {
    userID == source.userId && sourceDigest == Self.digest(source.token)
  }

  func matching(_ source: AuthCredentials) -> Self? {
    matches(source) ? self : nil
  }

  func validate() throws {
    guard version == 1, userID > 0, sourceDigest.count == 32,
          !permanent.temporary, permanent.expiresAt == nil
    else { throw AuthStorageError.encodingFailed }
    _ = try InlineProtocolAuthorization(
      key: permanent.key, keyID: permanent.keyID, serverSalt: permanent.serverSalt,
      temporary: false, expiresAt: nil
    )
    if let credentials {
      try credentials.validate()
      guard credentials.userId == userID, credentials.temporary != nil,
            hasPermanent(credentials.permanent)
      else { throw AuthStorageError.encodingFailed }
    }
  }

  func hasPermanent(_ authorization: InlineProtocolAuthorization) -> Bool {
    permanent.keyID == authorization.keyID && permanent.key == authorization.key
  }

  private static func digest(_ token: String) -> Data {
    Data(SHA256.hash(data: Data(token.utf8)))
  }
}
