import Auth
import Combine
import GRDB
import InlineKit
import Logger
import UIKit
import UserNotifications

/// The single owner of the app icon badge while the app runs: the number of chats shown in blue
/// (`Dialog.appBadgeSQL`). While the app is not active the server owns it through `aps.badge`.
///
/// The local count is applied only while the app is active, and once more on the way to the
/// background. A background launch reads a database that has not synced yet and would lower a
/// correct server badge.
@MainActor
final class AppIconBadgeService {
  static let shared = AppIconBadgeService()

  private let log = Log.scoped("AppIconBadge")
  private var cancellables = Set<AnyCancellable>()
  private var countCancellable: AnyCancellable?
  private var latestCount: Int?

  func start() {
    guard cancellables.isEmpty else { return }

    // A locked-device launch can report signed out before the keychain is readable, so signing
    // out never clears the badge here. Logout clears it explicitly.
    Auth.shared.$isLoggedIn
      .removeDuplicates()
      .sink { [weak self] isLoggedIn in self?.setObserving(isLoggedIn) }
      .store(in: &cancellables)

    NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
      .sink { [weak self] _ in self?.applyLatest() }
      .store(in: &cancellables)
    NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
      .sink { [weak self] _ in self?.applyLatest(evenIfInactive: true) }
      .store(in: &cancellables)
  }

  /// Clears the badge for a signed-out device. The server stops pushing to the revoked session.
  /// Observation stops when `isLoggedIn` turns false, so an aborted logout keeps counting.
  func clearForLogout() {
    apply(0)
  }

  private func setObserving(_ isLoggedIn: Bool) {
    countCancellable = nil
    latestCount = nil
    guard isLoggedIn else { return }

    countCancellable = ValueObservation
      .tracking { db in try Dialog.fetchAppBadgeCount(db) }
      .removeDuplicates()
      .publisher(in: AppDatabase.shared.reader)
      .sink(
        receiveCompletion: { [weak self] completion in
          guard case let .failure(error) = completion else { return }
          self?.log.error("App badge observation failed", error: error)
        },
        receiveValue: { [weak self] count in
          self?.latestCount = count
          self?.applyLatest()
        }
      )
  }

  private func applyLatest(evenIfInactive: Bool = false) {
    guard let latestCount else { return }
    guard evenIfInactive || UIApplication.shared.applicationState == .active else { return }
    apply(latestCount)
  }

  /// Not deduplicated: pushes change the badge behind this service's back while inactive.
  private func apply(_ count: Int) {
    UNUserNotificationCenter.current().setBadgeCount(count) { [log] error in
      if let error { log.error("Setting the app badge failed", error: error) }
    }
  }
}
