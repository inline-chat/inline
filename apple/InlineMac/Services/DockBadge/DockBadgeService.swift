import Auth
import Combine
import Observation

/// The single owner of macOS Dock badge behavior.
///
/// Keep all Dock badge changes centralized here to avoid scattered `NSApplication.shared.dockTile` writes.
@MainActor
final class DockBadgeService {
  private let auth: Auth
  private let appSettings: AppSettings
  private let unreadCounts: UnreadCountsModel
  private let dockBadgeController = DockBadgeController()

  private var cancellables = Set<AnyCancellable>()
  private var unreadCountsObservationActive = false
  private var unreadCountsObservationGeneration = 0

  init(
    auth: Auth = .shared,
    appSettings: AppSettings = .shared,
    unreadCounts: UnreadCountsModel
  ) {
    self.auth = auth
    self.appSettings = appSettings
    self.unreadCounts = unreadCounts
  }

  func start() {
    // Re-evaluate badge behavior when auth or settings change.
    auth.$isLoggedIn
      .removeDuplicates()
      .sink { [weak self] _ in
        self?.refreshUnreadBadging(applyImmediately: true)
      }
      .store(in: &cancellables)

    appSettings.$showDockBadgeUnreadDMs
      .removeDuplicates()
      .sink { [weak self] enabled in
        // When re-enabled, apply the current count immediately (no debounce) so the badge appears right away.
        self?.refreshUnreadBadging(applyImmediately: enabled)
      }
      .store(in: &cancellables)

    refreshUnreadBadging(applyImmediately: true)
  }

  func prepareForTermination() {
    cancellables.removeAll()
    cancelUnreadCountObservation()
    dockBadgeController.setUnreadCount(0, debounceIncreases: false)
  }

  // MARK: - Unread chats

  private func refreshUnreadBadging(applyImmediately: Bool) {
    let shouldObserve = auth.isLoggedIn && appSettings.showDockBadgeUnreadDMs

    if !shouldObserve {
      cancelUnreadCountObservation()
      dockBadgeController.setUnreadCount(0, debounceIncreases: false)
      return
    }

    unreadCounts.start()

    if applyImmediately {
      applyDockBadgeCount(debounceIncreases: false)
    }

    observeUnreadCountsIfNeeded()
  }

  private func observeUnreadCountsIfNeeded() {
    guard unreadCountsObservationActive == false else { return }

    unreadCountsObservationActive = true
    let observationGeneration = unreadCountsObservationGeneration

    withObservationTracking {
      _ = unreadCounts.prominentUnreadChatCount
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self else { return }
        guard unreadCountsObservationGeneration == observationGeneration else { return }
        unreadCountsObservationActive = false
        applyDockBadgeCount(debounceIncreases: true)
        observeUnreadCountsIfNeeded()
      }
    }
  }

  private func cancelUnreadCountObservation() {
    unreadCountsObservationGeneration += 1
    unreadCountsObservationActive = false
  }

  private func applyDockBadgeCount(debounceIncreases: Bool) {
    dockBadgeController.setUnreadCount(
      unreadCounts.prominentUnreadChatCount,
      debounceIncreases: debounceIncreases
    )
  }
}
