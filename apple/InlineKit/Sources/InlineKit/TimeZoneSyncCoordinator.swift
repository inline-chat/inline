import Auth
import Foundation
import Logger
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor
public final class TimeZoneSyncCoordinator {
  public static let shared = TimeZoneSyncCoordinator()

  private let log = Log.scoped("TimeZoneSyncCoordinator")
  private var didStart = false
  private var didAttemptStartupSync = false
  private var lastSyncedTimeZone: String?
  private var authTask: Task<Void, Never>?
  private var syncTask: Task<Void, Never>?
  private var systemTimeZoneObserver: NSObjectProtocol?
  private var appStateObservers: [NSObjectProtocol] = []

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

    // A suspended app can miss the system notification above. iOS queues a significant
    // time change until the app returns, and becoming active covers the rest.
    #if os(iOS)
    let appStateNotifications = [
      UIApplication.didBecomeActiveNotification,
      UIApplication.significantTimeChangeNotification,
    ]
    #elseif os(macOS)
    let appStateNotifications = [NSApplication.didBecomeActiveNotification]
    #else
    let appStateNotifications: [Notification.Name] = []
    #endif
    appStateObservers = appStateNotifications.map { name in
      NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.syncIfNeeded(reason: "app active")
        }
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
          lastSyncedTimeZone = nil
        }
      }
    }
  }

  private func syncIfNeeded(reason: String) {
    guard Auth.shared.getIsLoggedIn(), !Auth.shared.getHasPendingAccountTransition() else { return }

    // Foundation caches the system zone until its change notification lands, which a
    // suspended app may never see. Re-read it so a missed change is not hidden.
    NSTimeZone.resetSystemTimeZone()
    let timeZone = TimeZone.autoupdatingCurrent.identifier
    guard timeZone != lastSyncedTimeZone else { return }

    syncTask?.cancel()
    let auth = Auth.shared.handle
    syncTask = Task { [weak self] in
      do {
        try Task.checkCancellation()
        try auth.requireAccountMutationAllowed()
        try await Self.waitForRealtimeConnection()
        try auth.requireAccountMutationAllowed()
        try await DataManager.shared.updateTimezone()
        try Task.checkCancellation()
        self?.lastSyncedTimeZone = timeZone
        self?.log.debug("Synced time zone reason=\(reason)")
      } catch {
        if error is CancellationError { return }
        self?.log.error("Failed to sync time zone reason=\(reason)", error: error)
      }
      await MainActor.run { self?.syncTask = nil }
    }
  }

  private static func waitForRealtimeConnection() async throws {
    for await state in await Api.realtime.connectionStates() {
      try Task.checkCancellation()
      if case .updating = state { return }
      if case .connected = state { return }
    }
    throw CancellationError()
  }
}
