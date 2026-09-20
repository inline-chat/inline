import AppKit
import Observation
import ServiceManagement
import WidgetKit
import OSLog

@MainActor @Observable
final class MetricsStore {
  var snapshot: MetricsSnapshot = .signedOut
  var isSignedIn = false
  var isBusy = false
  var errorMessage: String?
  var launchAtLogin = SMAppService.mainApp.status == .enabled
  private var session: AdminSession?
  private let refreshActivity = NSBackgroundActivityScheduler(identifier: "chat.inline.tools.metrics.refresh")
  private var wakeObserver: NSObjectProtocol?
  private var lastPublishedSnapshot: MetricsSnapshot?
  private var lastWidgetReload: Date?
  private let logger = Logger(subsystem: "chat.inline.tools.metrics", category: "refresh")
  private let client = AdminClient()
  private var storage: SnapshotStore?

  init() {
    do {
      storage = try SnapshotStore.shared()
      session = try SessionKeychain.load()
      if let session, session.expiresAt > Date() {
        isSignedIn = true
        snapshot = storage?.read() ?? .signedOut
      } else {
        try SessionKeychain.delete()
        session = nil
        try storage?.write(.signedOut)
        WidgetCenter.shared.reloadTimelines(ofKind: "InlineMetricsWidget")
      }
    } catch { errorMessage = error.localizedDescription }
    // A macOS background activity participates in App Nap scheduling; it belongs
    // to the companion's lifetime, not the dashboard window's lifetime.
    refreshActivity.interval = MetricsSnapshot.refreshInterval
    refreshActivity.tolerance = 30
    refreshActivity.repeats = true
    refreshActivity.qualityOfService = .utility
    refreshActivity.schedule { [weak self] completion in
      Task { @MainActor in
        self?.logger.info("Automatic metrics refresh started.")
        await self?.refresh(forceWidgetReload: false)
        completion(.finished)
      }
    }
    Task { await refresh() }
    wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in await self?.refresh() }
    }
  }

  func signIn(email: String, password: String, code: String) async {
    guard !isBusy else { return }
    isBusy = true
    errorMessage = nil
    defer { isBusy = false }
    do {
      // Fail before requesting credentials if the shared container is misconfigured.
      storage = try SnapshotStore.shared()
      let newSession = try await client.login(
        email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password,
        code: code.trimmingCharacters(in: .whitespacesAndNewlines)
      )
      do { try SessionKeychain.save(newSession) } catch {
        try? await client.logout(session: newSession)
        throw error
      }
      session = newSession
      isSignedIn = true
      // Never display a previous account's metrics while loading a new account.
      snapshot = MetricsSnapshot(state: .unavailable, sessionExpiresAt: newSession.expiresAt)
      try publish()
      try await fetch(newSession)
    } catch {
      handle(error)
    }
  }

  func refresh(forceWidgetReload: Bool = true) async {
    guard !isBusy, let session else { return }
    isBusy = true
    defer { isBusy = false }
    do {
      guard session.expiresAt > Date() else {
        throw AdminClientError.rejected(status: 401, code: "unauthorized")
      }
      try await fetch(session, forceWidgetReload: forceWidgetReload)
      errorMessage = nil
    } catch { handle(error) }
  }

  func signOut() async {
    guard !isBusy else { return }
    isBusy = true
    defer { isBusy = false }
    let previous = session
    session = nil
    isSignedIn = false
    snapshot = .signedOut
    errorMessage = nil
    // Both removals must be attempted even if one store is temporarily unavailable.
    do { try SessionKeychain.delete() } catch { errorMessage = error.localizedDescription }
    do { try publish() } catch { errorMessage = error.localizedDescription }
    if let previous {
      do { try await client.logout(session: previous) } catch {
        errorMessage = "Signed out on this Mac. The server session could not be revoked and will expire automatically."
      }
    }
  }

  func setLaunchAtLogin(_ enabled: Bool) {
    do {
      if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
      launchAtLogin = SMAppService.mainApp.status == .enabled
      if enabled && !launchAtLogin {
        errorMessage = "Allow Inline Metrics in System Settings → General → Login Items."
      }
    } catch { errorMessage = error.localizedDescription }
  }

  private func fetch(_ session: AdminSession, forceWidgetReload: Bool = false) async throws {
    let metrics = try await client.overview(session: session)
    snapshot = MetricsSnapshot(state: .ready, metrics: metrics, fetchedAt: Date(), sessionExpiresAt: session.expiresAt)
    try publish(forceReload: forceWidgetReload)
    logger.info("Metrics fetch completed; shared snapshot saved.")
  }

  private func handle(_ error: Error) {
    if case AdminClientError.rejected(let status, _) = error, status == 401 || status == 403 {
      session = nil
      isSignedIn = false
      snapshot = MetricsSnapshot(state: .expired)
      try? SessionKeychain.delete()
    } else if isSignedIn {
      snapshot.state = .unavailable
    }
    errorMessage = error.localizedDescription
    do { try publish() } catch {
      errorMessage = "The widget’s saved data could not be updated. \(error.localizedDescription)"
    }
  }

  private func publish(forceReload: Bool = false) throws {
    guard let storage else { throw CocoaError(.fileNoSuchFile) }
    try storage.write(snapshot)
    let now = Date()
    if forceReload || snapshot.needsWidgetReload(comparedTo: lastPublishedSnapshot, lastReload: lastWidgetReload, now: now) {
      WidgetCenter.shared.reloadTimelines(ofKind: "InlineMetricsWidget")
      lastWidgetReload = now
      logger.info("Widget reload requested after data change or freshness interval.")
    }
    lastPublishedSnapshot = snapshot
  }
}
