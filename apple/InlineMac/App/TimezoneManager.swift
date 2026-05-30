import Auth
import Foundation
import InlineKit
import Logger

@MainActor
final class TimezoneManager {
  static let shared = TimezoneManager()

  private let log = Log.scoped("TimezoneManager")
  private let startupDelayNs: UInt64 = 5_000_000_000
  private let changeDelayNs: UInt64 = 1_000_000_000

  private var didStart = false
  private var didSeeMainWindow = false
  private var didScheduleStartupSync = false
  private var pendingForceSync = false
  private var lastSyncedTimeZone: String?

  private var systemTimeZoneObserver: NSObjectProtocol?
  private var authTask: Task<Void, Never>?
  private var scheduledSync: Task<Void, Never>?

  private init() {}

  deinit {
    if let systemTimeZoneObserver {
      NotificationCenter.default.removeObserver(systemTimeZoneObserver)
    }
    authTask?.cancel()
    scheduledSync?.cancel()
  }

  func start() {
    guard !didStart else { return }

    didStart = true
    observeSystemTimeZoneChanges()
    observeAuthEvents()
    scheduleStartupSyncIfReady()
  }

  func mainWindowDidOpen() {
    guard !didSeeMainWindow else { return }

    didSeeMainWindow = true
    scheduleStartupSyncIfReady()
  }

  private func observeSystemTimeZoneChanges() {
    systemTimeZoneObserver = NotificationCenter.default.addObserver(
      forName: .NSSystemTimeZoneDidChange,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.systemTimeZoneDidChange()
      }
    }
  }

  private func observeAuthEvents() {
    authTask = Task { @MainActor [weak self] in
      for await event in Auth.shared.events {
        switch event {
          case .login:
            self?.loginDidComplete()
          case .logout:
            self?.logoutDidComplete()
        }
      }
    }
  }

  private func scheduleStartupSyncIfReady() {
    guard didStart, didSeeMainWindow, !didScheduleStartupSync else { return }

    didScheduleStartupSync = true
    scheduleSync(reason: "startup", delayNs: startupDelayNs)
  }

  private func loginDidComplete() {
    guard didSeeMainWindow else { return }

    let delayNs = didScheduleStartupSync ? changeDelayNs : startupDelayNs
    scheduleSync(reason: "login", delayNs: delayNs)
  }

  private func logoutDidComplete() {
    scheduledSync?.cancel()
    scheduledSync = nil
    pendingForceSync = false
    lastSyncedTimeZone = nil
  }

  private func systemTimeZoneDidChange() {
    scheduleSync(reason: "system timezone changed", delayNs: changeDelayNs, force: true)
  }

  private func scheduleSync(reason: String, delayNs: UInt64, force: Bool = false) {
    if force {
      pendingForceSync = true
    }

    guard scheduledSync == nil else { return }

    scheduledSync = Task { @MainActor [weak self] in
      if delayNs > 0 {
        try? await Task.sleep(nanoseconds: delayNs)
      }
      guard !Task.isCancelled else { return }

      await self?.runScheduledSync(reason: reason, force: force)
    }
  }

  private func runScheduledSync(reason: String, force: Bool) async {
    scheduledSync = nil

    let forceSync = force || pendingForceSync
    pendingForceSync = false

    await sync(reason: reason, force: forceSync)
  }

  private func sync(reason: String, force: Bool) async {
    guard Auth.shared.getIsLoggedIn() else {
      log.debug("Skipping timezone sync while logged out reason=\(reason)")
      return
    }

    let timeZone = TimeZone.autoupdatingCurrent.identifier
    guard force || timeZone != lastSyncedTimeZone else { return }

    do {
      try await DataManager.shared.updateTimezone()
      lastSyncedTimeZone = timeZone
      log.debug("Synced timezone \(timeZone) reason=\(reason)")
    } catch {
      log.error("Failed to sync timezone reason=\(reason)", error: error)
    }
  }
}
