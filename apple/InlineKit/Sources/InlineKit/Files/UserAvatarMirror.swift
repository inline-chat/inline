import Auth
import Foundation
import Logger

/// Copies a remote avatar into the profile cache once per account and photo, however many
/// avatar views show it. Per-view tracking let every new row repeat the fetch and write.
@MainActor
public final class UserAvatarMirror {
  public static let shared = UserAvatarMirror()

  /// How long a failed photo is left alone, so views appearing meanwhile don't repeat the work.
  static let retryDelay: Duration = .seconds(5 * 60)

  private struct Key: Hashable {
    let userId: Int64
    let sourceURL: URL
    let avatarIdentity: String?
  }

  private enum State {
    case running
    case mirrored
    case failed(ContinuousClock.Instant)
  }

  private let auth: AuthHandle
  private let database: AppDatabase
  private let directory: URL?
  private let clock = ContinuousClock()
  private var account: AuthAccountMutationToken?
  private var states: [Key: State] = [:]

  init(auth: AuthHandle = Auth.shared.handle, database: AppDatabase = .shared, directory: URL? = nil) {
    self.auth = auth
    self.database = database
    self.directory = directory
  }

  /// Starts mirroring unless this photo is already mirrored, in flight or failed recently.
  /// Returns the started work, or nil when nothing was started.
  @discardableResult
  public func mirror(
    userId: Int64,
    sourceURL: URL,
    expectedAvatarIdentity: String?,
    fetchOriginal: @escaping @MainActor @Sendable () async throws -> Data
  ) -> Task<Void, Never>? {
    guard let account = try? auth.beginAccountMutation() else { return nil }
    if account != self.account {
      // Progress belongs to the account it was made under.
      self.account = account
      states = [:]
    }

    let key = Key(userId: userId, sourceURL: sourceURL, avatarIdentity: expectedAvatarIdentity)
    switch states[key] {
      case .running, .mirrored:
        return nil
      case let .failed(failedAt) where clock.now - failedAt < Self.retryDelay:
        return nil
      case .failed, nil:
        break
    }
    states[key] = .running

    return Task { [auth, database, directory] in
      let outcome: State
      do {
        let data = try await fetchOriginal()
        try auth.validateAccountMutation(account)
        try await User.cacheImageData(
          userId: userId,
          data: data,
          expectedSourceURL: sourceURL,
          expectedAvatarIdentity: expectedAvatarIdentity,
          accountToken: account,
          auth: auth,
          database: database,
          directory: directory
        )
        outcome = .mirrored
      } catch {
        Log.shared.error("Failed to cache image", error: error)
        outcome = .failed(clock.now)
      }
      guard self.account == account else { return }
      states[key] = outcome
    }
  }
}
