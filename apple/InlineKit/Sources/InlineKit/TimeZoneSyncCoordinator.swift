import Auth
import Foundation
import Logger

@MainActor
public final class TimeZoneSyncCoordinator {
  public static let shared = TimeZoneSyncCoordinator()

  private let log = Log.scoped("TimeZoneSyncCoordinator")
  private var didStart = false
  private var didAttemptStartupSync = false
  private var lastAttemptedTimeZone: String?
  private var authTask: Task<Void, Never>?
  private var syncTask: Task<Void, Never>?
  private var systemTimeZoneObserver: NSObjectProtocol?

  private init() {}

  public func start() {
    guard !didStart else { return }
    didStart = true

    systemTimeZoneObserver = NotificationCenter.default.addObserver(
      forName: .NSSystemTimeZoneDidChange,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.syncIfNeeded(reason: "system change")
      }
    }

    authTask = Task { @MainActor [weak self] in
      for await snapshot in Auth.shared.snapshots {
        guard let self else { return }
        if snapshot.isLoggedIn {
          guard !didAttemptStartupSync else { continue }
          didAttemptStartupSync = true
          syncIfNeeded(reason: "startup")
        } else if snapshot.didHydrate {
          syncTask?.cancel()
          syncTask = nil
          didAttemptStartupSync = false
          lastAttemptedTimeZone = nil
        }
      }
    }
  }

  private func syncIfNeeded(reason: String) {
    guard Auth.shared.getIsLoggedIn(), !Auth.shared.getHasPendingAccountTransition() else { return }

    let timeZone = TimeZone.autoupdatingCurrent.identifier
    guard timeZone != lastAttemptedTimeZone else { return }
    lastAttemptedTimeZone = timeZone

    syncTask?.cancel()
    let auth = Auth.shared.handle
    syncTask = Task { [weak self] in
      do {
        try Task.checkCancellation()
        try auth.requireAccountMutationAllowed()
        try await DataManager.shared.updateTimezone()
        try Task.checkCancellation()
        self?.log.debug("Synced time zone reason=\(reason)")
      } catch {
        if error is CancellationError { return }
        self?.log.error("Failed to sync time zone reason=\(reason)", error: error)
      }
      await MainActor.run { self?.syncTask = nil }
    }
  }
}
