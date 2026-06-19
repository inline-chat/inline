import Combine
import Foundation
import InlineKit
import InlineProtocol
import RealtimeV2

@MainActor
final class AccountSettingsViewModel: ObservableObject {
  @Published private(set) var sessions: [InlineProtocol.AccountSession] = []
  @Published private(set) var isLoadingSessions = false
  @Published private(set) var isSavingProfile = false
  @Published private(set) var isCheckingUsername = false
  @Published private(set) var isSavingUsername = false
  @Published private(set) var revokingSessionID: Int64?
  @Published var usernameState: UsernameState = .idle
  @Published var errorState: ErrorState?

  enum UsernameState: Equatable {
    case idle
    case checking
    case available
    case unavailable
    case reserved
    case unchanged
    case willClear
    case invalid(String)

    var message: String? {
      switch self {
        case .idle:
          nil
        case .checking:
          "Checking..."
        case .available:
          "Username is available."
        case .unavailable:
          "Username is already taken."
        case .reserved:
          "Username is reserved."
        case .unchanged:
          "This is your current username."
        case .willClear:
          "Username will be removed."
        case let .invalid(message):
          message
      }
    }

    var canSave: Bool {
      switch self {
        case .available, .unchanged, .willClear:
          true
        case .idle, .checking, .unavailable, .reserved, .invalid:
          false
      }
    }
  }

  struct ErrorState {
    let title: String
    let message: String
  }

  func loadSessions(realtimeV2: RealtimeV2) async {
    guard !isLoadingSessions else { return }
    isLoadingSessions = true
    defer { isLoadingSessions = false }

    do {
      sessions = try await realtimeV2.getSessions().sessions
    } catch {
      showError(title: "Could Not Load Sessions", error: error)
    }
  }

  func revoke(_ session: InlineProtocol.AccountSession, realtimeV2: RealtimeV2) async {
    guard !session.current, revokingSessionID == nil else { return }
    revokingSessionID = session.id
    defer { revokingSessionID = nil }

    do {
      _ = try await realtimeV2.revokeSession(session.id)
      sessions.removeAll { $0.id == session.id }
    } catch {
      showError(title: "Could Not Revoke Session", error: error)
    }
  }

  func saveProfile(
    firstName rawFirstName: String,
    lastName rawLastName: String,
    bio rawBio: String,
    realtimeV2: RealtimeV2
  ) async -> Bool {
    guard !isSavingProfile else { return false }

    let firstName = rawFirstName.trimmed
    let lastName = rawLastName.trimmed
    let bio = rawBio.trimmed
    guard !firstName.isEmpty else {
      errorState = ErrorState(title: "Name Required", message: "Enter at least a first name.")
      return false
    }

    isSavingProfile = true
    defer { isSavingProfile = false }

    do {
      let result = try await realtimeV2.updateProfile(
        firstName: firstName,
        lastName: lastName,
        bio: bio
      )
      await realtimeV2.applyUpdates(result.updates)
      try await save(result.user)
      return true
    } catch {
      showError(title: "Could Not Save Profile", error: error)
      return false
    }
  }

  func resetUsernameState() {
    usernameState = .idle
  }

  func usernameChanged(_ rawUsername: String, currentUsername: String?) {
    let username = cleanUsername(rawUsername)
    if username.isEmpty, currentUsername != nil {
      usernameState = .willClear
    } else {
      usernameState = .idle
    }
  }

  func checkUsername(_ rawUsername: String, currentUsername: String?, realtimeV2: RealtimeV2) async {
    let username = cleanUsername(rawUsername)
    if username == currentUsername {
      usernameState = .unchanged
      return
    }
    guard validateUsername(username) else { return }

    guard !isCheckingUsername else { return }
    isCheckingUsername = true
    usernameState = .checking
    defer { isCheckingUsername = false }

    do {
      let result = try await realtimeV2.checkUsername(username)
      usernameState = state(for: result.availability)
    } catch {
      usernameState = .idle
      showError(title: "Could Not Check Username", error: error)
    }
  }

  func saveUsername(_ rawUsername: String, currentUsername: String?, realtimeV2: RealtimeV2) async -> Bool {
    guard !isSavingUsername else { return false }

    let username = cleanUsername(rawUsername)
    if username.isEmpty {
      guard currentUsername != nil else {
        usernameState = .invalid("Enter a username.")
        return false
      }
    } else if username != currentUsername {
      guard validateUsername(username) else { return false }
    }

    isSavingUsername = true
    defer { isSavingUsername = false }

    do {
      let result = try await realtimeV2.changeUsername(username)
      await realtimeV2.applyUpdates(result.updates)
      try await save(result.user)
      usernameState = .unchanged
      return true
    } catch {
      showError(title: "Could Not Save Username", error: error)
      return false
    }
  }

  private func validateUsername(_ username: String) -> Bool {
    guard !username.isEmpty else {
      usernameState = .invalid("Enter a username.")
      return false
    }
    guard username.count >= 2 else {
      usernameState = .invalid("Usernames must be at least 2 characters.")
      return false
    }
    return true
  }

  private func cleanUsername(_ rawUsername: String) -> String {
    var username = rawUsername.trimmed
    while username.hasPrefix("@") {
      username.removeFirst()
    }
    return username
  }

  private func state(for availability: InlineProtocol.UsernameAvailability) -> UsernameState {
    switch availability {
      case .usernameAvailable:
        .available
      case .usernameCurrent:
        .unchanged
      case .usernameTaken:
        .unavailable
      case .usernameReserved:
        .reserved
      case .usernameInvalid:
        .invalid("Usernames must be at least 2 characters.")
      case .unspecified, .UNRECOGNIZED(_):
        .idle
    }
  }

  private func save(_ user: InlineProtocol.User) async throws {
    _ = try await AppDatabase.shared.dbWriter.write { db in
      try User.save(db, user: user)
    }
  }

  private func showError(title: String, error: Error) {
    errorState = ErrorState(
      title: title,
      message: error.localizedDescription
    )
  }
}

private extension String {
  var trimmed: String {
    trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
