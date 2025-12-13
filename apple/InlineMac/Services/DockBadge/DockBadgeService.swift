import Auth
import Combine
import InlineKit

/// The single owner of macOS Dock badge behavior.
///
/// Keep all Dock badge changes centralized here to avoid scattered `NSApplication.shared.dockTile` writes.
/// Today we only badge unread DMs, but future badge sources (mentions, all unread, etc.) should be added
/// as additional observations in this service.
@MainActor
final class DockBadgeService {
  private let auth: Auth
  private let appSettings: AppSettings
  private let database: AppDatabase
  private let dockBadgeController = DockBadgeController()

  private var cancellables = Set<AnyCancellable>()
  private var unreadDMCountCancellable: AnyCancellable?

  init(
    auth: Auth = .shared,
    appSettings: AppSettings = .shared,
    database: AppDatabase = .shared
  ) {
    self.auth = auth
    self.appSettings = appSettings
    self.database = database
  }

  func start() {
    // Re-evaluate badge behavior when auth or settings change.
    auth.$isLoggedIn
      .removeDuplicates()
      .sink { [weak self] _ in
        self?.refreshUnreadDMBadging(applyImmediately: true)
      }
      .store(in: &cancellables)

    appSettings.$showDockBadgeUnreadDMs
      .removeDuplicates()
      .sink { [weak self] enabled in
        // When re-enabled, apply the current count immediately (no debounce) so the badge appears right away.
        self?.refreshUnreadDMBadging(applyImmediately: enabled)
      }
      .store(in: &cancellables)

    refreshUnreadDMBadging(applyImmediately: true)
  }

  // MARK: - Unread DMs

  private func refreshUnreadDMBadging(applyImmediately: Bool) {
    let shouldObserve = auth.isLoggedIn && appSettings.showDockBadgeUnreadDMs

    if !shouldObserve {
      unreadDMCountCancellable?.cancel()
      unreadDMCountCancellable = nil
      dockBadgeController.setUnreadDMCount(0, debounceIncreases: false)
      return
    }

    if applyImmediately {
      let currentCount = UnreadDMCount.current(db: database)
      dockBadgeController.setUnreadDMCount(currentCount, debounceIncreases: false)
    }

    if unreadDMCountCancellable != nil {
      return
    }

    unreadDMCountCancellable = UnreadDMCount.publisher(db: database)
      .sink { [weak self] count in
        self?.dockBadgeController.setUnreadDMCount(count, debounceIncreases: true)
      }
  }
}

