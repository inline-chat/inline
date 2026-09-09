import Auth
import GRDB
import InlineProtocol
import RealtimeV2
import Testing
@testable import InlineKit

@Suite("Onboarding startup")
struct OnboardingSessionTests {
  private enum Failure: Error {
    case offline
  }

  @Test("pending provider profiles resume even when a name was prefilled")
  func pendingProfile() {
    #expect(OnboardingSession.requiresSetup(pendingSetup: true, firstName: "Test"))
  }

  @Test("complete legacy profiles do not require a username or a new setup flag")
  func completedProfile() {
    #expect(!OnboardingSession.requiresSetup(pendingSetup: false, firstName: "Test"))
    #expect(!OnboardingSession.requiresSetup(pendingSetup: nil, firstName: "Test"))
  }

  @Test("missing profile data must not route to the main app")
  func missingProfile() {
    #expect(OnboardingSession.requiresSetup(pendingSetup: false, firstName: nil))
    #expect(OnboardingSession.requiresSetup(pendingSetup: nil, firstName: "  "))
  }

  @Test("cached profiles resolve without constructing a connection", arguments: [nil, false, true] as [Bool?])
  @MainActor
  func cachedProfile(pendingSetup: Bool?) async throws {
    let auth = Auth.mocked(authenticated: true)
    let database = AppDatabase.empty()
    var user = InlineKit.User(id: 1, email: nil, firstName: "Test")
    user.pendingSetup = pendingSetup
    let cached = user
    try await database.dbWriter.write { db in try cached.insert(db) }

    let result = try await OnboardingSession.pendingProfileUserID(database: database, auth: auth.handle) { _ in
      Issue.record("Cached startup must not need network admission or getMe")
      throw Failure.offline
    }
    #expect(result == (pendingSetup == true ? 1 : nil))
  }

  @Test("a cached legacy profile with no name resumes setup locally")
  @MainActor
  func cachedIncompleteProfile() async throws {
    let auth = Auth.mocked(authenticated: true)
    let database = AppDatabase.empty()
    try await database.dbWriter.write { db in
      try InlineKit.User(id: 1, email: nil, firstName: nil).insert(db)
    }
    let result = try await OnboardingSession.pendingProfileUserID(database: database, auth: auth.handle) { _ in
      Issue.record("An incomplete cached profile also resolves locally")
      throw Failure.offline
    }
    #expect(result == 1)
  }

  @Test("a missing profile is fetched once and reused on the next startup", arguments: [false, true])
  @MainActor
  func missingProfileRecovery(pendingSetup: Bool) async throws {
    let auth = Auth.mocked(authenticated: true)
    let database = AppDatabase.empty()
    var fetches = 0
    let result = try await OnboardingSession.pendingProfileUserID(database: database, auth: auth.handle) { account in
      fetches += 1
      return .with {
        $0.id = account.userID
        $0.firstName = "Test"
        $0.pendingSetup = pendingSetup
      }
    }
    #expect(fetches == 1)
    #expect(result == (pendingSetup ? 1 : nil))
    let cachedResult = try await OnboardingSession.pendingProfileUserID(database: database, auth: auth.handle) { _ in
      Issue.record("Recovered profile must be persisted for the next launch")
      throw Failure.offline
    }
    #expect(cachedResult == result)
  }

  @Test("unavailable profile recovery does not admit main")
  @MainActor
  func offlineMissingProfile() async throws {
    let auth = Auth.mocked(authenticated: true)
    let database = AppDatabase.empty()
    await #expect(throws: Failure.offline) {
      try await OnboardingSession.pendingProfileUserID(database: database, auth: auth.handle) { _ in
        throw Failure.offline
      }
    }
    #expect(try await InlineKit.User.fetch(id: 1, from: database) == nil)
  }

  @Test("account changes during recovery cannot persist or route the previous account")
  @MainActor
  func accountChangedDuringRecovery() async throws {
    let auth = Auth.mocked(authenticated: true)
    let database = AppDatabase.empty()
    await #expect(throws: AuthStorageError.loginUnavailable) {
      try await OnboardingSession.pendingProfileUserID(database: database, auth: auth.handle) { account in
        try await auth.saveCredentials(token: "2:startup-test", userId: 2)
        return .with {
          $0.id = account.userID
          $0.firstName = "Old account"
        }
      }
    }
    #expect(try await InlineKit.User.fetch(id: 1, from: database) == nil)
  }

  @Test("profile recovery rejects a response for another account")
  @MainActor
  func mismatchedRecovery() async throws {
    let auth = Auth.mocked(authenticated: true)
    let database = AppDatabase.empty()
    await #expect {
      try await OnboardingSession.pendingProfileUserID(database: database, auth: auth.handle) { _ in
        .with {
          $0.id = 2
          $0.firstName = "Wrong account"
        }
      }
    } throws: { error in
      guard case RealtimeDirectRpcError.notAuthorized = error else { return false }
      return true
    }
    #expect(try await InlineKit.User.fetch(id: 2, from: database) == nil)
  }

  @Test("cancelled recovery cannot persist or publish a profile")
  @MainActor
  func cancelledRecovery() async throws {
    let auth = Auth.mocked(authenticated: true)
    let database = AppDatabase.empty()
    let task = Task {
      try await OnboardingSession.pendingProfileUserID(database: database, auth: auth.handle) { account in
        withUnsafeCurrentTask { $0?.cancel() }
        return .with {
          $0.id = account.userID
          $0.firstName = "Test"
        }
      }
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try await InlineKit.User.fetch(id: 1, from: database) == nil)
  }
}
