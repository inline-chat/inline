import Foundation
import GRDB
import Testing
@testable import Auth
@testable import InlineKit

@MainActor
@Suite("User avatar mirror", .serialized)
struct UserAvatarMirrorTests {
  @Test("many views of one photo fetch and write it once")
  func coalescesRequests() async throws {
    let fixture = try await MirrorFixture()
    defer { fixture.cleanUp() }
    let fetch = ControlledFetch()

    let task = try #require(fixture.mirror(fetch))
    for _ in 0 ..< 5 {
      #expect(fixture.mirror(fetch) == nil)
    }
    fetch.complete(.success(Data([0xFF, 0xD8, 0xFF])))
    await task.value

    #expect(fetch.calls == 1)
    let localPath = try #require(try await fixture.localPath())
    #expect(localPath.hasPrefix(User.remoteProfilePhotoCacheFilePrefix))
    #expect(fixture.mirror(fetch) == nil)
    #expect(fetch.calls == 1)
  }

  @Test("a rejected photo is not fetched again by the next views")
  func keepsRecentFailure() async throws {
    let fixture = try await MirrorFixture(storedPhotoURL: "https://example.com/newer.jpg")
    defer { fixture.cleanUp() }
    let fetch = ControlledFetch()
    fetch.complete(.success(Data([0xFF, 0xD8, 0xFF])))

    let task = try #require(fixture.mirror(fetch))
    await task.value

    #expect(try await fixture.localPath() == nil)
    #expect(try fixture.mirroredFiles().isEmpty)
    #expect(fixture.mirror(fetch) == nil)
    #expect(fetch.calls == 1)
  }

  @Test("an account change drops the old account's write and lets the new account mirror")
  func accountChange() async throws {
    let fixture = try await MirrorFixture()
    defer { fixture.cleanUp() }
    let fetch = ControlledFetch()

    let task = try #require(fixture.mirror(fetch))
    try fixture.replaceAccount(userID: 7)
    fetch.complete(.success(Data([0xFF, 0xD8, 0xFF])))
    await task.value

    #expect(try await fixture.localPath() == nil)
    #expect(try fixture.mirroredFiles().isEmpty)
    let retry = try #require(fixture.mirror(fetch))
    await retry.value
    #expect(fetch.calls == 2)
    #expect(try await fixture.localPath() != nil)
  }
}

@MainActor
private final class ControlledFetch {
  private(set) var calls = 0
  private var result: Result<Data, Error>?
  private var waiters: [CheckedContinuation<Data, Error>] = []

  func fetch() async throws -> Data {
    calls += 1
    if let result { return try result.get() }
    return try await withCheckedThrowingContinuation { waiters.append($0) }
  }

  func complete(_ result: Result<Data, Error>) {
    self.result = result
    let waiting = waiters
    waiters = []
    for waiter in waiting {
      waiter.resume(with: result)
    }
  }
}

@MainActor
private final class MirrorFixture {
  let cache: AuthSnapshotCache
  let database = AppDatabase.empty()
  let directory: URL
  let mirror: UserAvatarMirror
  let photoURL = URL(string: "https://example.com/current.jpg")!

  init(storedPhotoURL: String = "https://example.com/current.jpg") async throws {
    let initial = AuthSnapshot(
      status: .authenticated(AuthCredentials(userId: 7, token: "7:avatar-test")),
      didHydrate: true
    )
    cache = AuthSnapshotCache(initial: initial)
    let store = AuthStore(
      cache: cache,
      mocked: true,
      namespace: UUID().uuidString,
      readSnapshot: { @Sendable _, _, _ in initial }
    )
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("avatar-mirror-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    mirror = UserAvatarMirror(auth: AuthHandle(cache: cache, store: store), database: database, directory: directory)

    try await database.dbWriter.write { db in
      var user = User(id: 1, email: nil, firstName: "User")
      user.profileFileUniqueId = "current-photo"
      user.profileCdnUrl = storedPhotoURL
      try user.save(db)
    }
  }

  func mirror(_ fetch: ControlledFetch) -> Task<Void, Never>? {
    mirror.mirror(userId: 1, sourceURL: photoURL, expectedAvatarIdentity: "unique:current-photo") {
      try await fetch.fetch()
    }
  }

  func localPath() async throws -> String? {
    try await database.reader.read { db in try User.fetchOne(db, id: 1)?.profileLocalPath }
  }

  func mirroredFiles() throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path)
  }

  /// Signs in again, which issues a new account generation even for the same user.
  func replaceAccount(userID: Int64) throws {
    let attempt = cache.makeLoginAttempt()
    #expect(cache.beginAuthorityStaging(attempt))
    let snapshot = AuthSnapshot(
      status: .authenticated(AuthCredentials(userId: userID, token: "\(userID):fresh-avatar-test")),
      didHydrate: true
    )
    #expect(cache.finishAuthorityStaging(snapshot, owner: attempt))
    #expect(cache.prepareStagedAuthorityFinalization(attempt))
    _ = try #require(cache.finalizeStagedAuthority(attempt, publish: { _ in }))
  }

  func cleanUp() {
    try? FileManager.default.removeItem(at: directory)
  }
}
