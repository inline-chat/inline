import Foundation
import Synchronization
#if os(iOS)
import UIKit
#endif

/// Whether the app is in the background, readable from any thread without an actor hop.
/// A transfer that stops making progress there was most likely suspended by the system, not
/// stalled by the network, so that time must not spend its retry budget: when the app returns,
/// the transfer picks up where it stopped instead of failing.
final class TransferLifecycle: Sendable {
  static let shared = TransferLifecycle(observingApplication: true)

  private struct State {
    var isInBackground = false
    var foregroundedAt: ContinuousClock.Instant?
  }

  private let state = Mutex(State())
  #if os(iOS)
  private let observers = Mutex<[NSObjectProtocol]>([])
  #endif

  init(observingApplication: Bool = false) {
    #if os(iOS)
    guard observingApplication else { return }
    let center = NotificationCenter.default
    // A nil queue delivers on the posting thread, so the state flips before any later callback.
    observers.withLock {
      $0 = [
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) {
          [weak self] _ in self?.enteredBackground()
        },
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) {
          [weak self] _ in self?.enteredForeground()
        },
      ]
    }
    #endif
  }

  /// When a transfer's stall budget starts counting: its last progress, or the app's return to
  /// the foreground if that came later. Nil while in the background: the budget does not run.
  func budgetStart(lastProgress: ContinuousClock.Instant) -> ContinuousClock.Instant? {
    state.withLock { state in
      guard !state.isInBackground else { return nil }
      guard let foregroundedAt = state.foregroundedAt else { return lastProgress }
      return max(lastProgress, foregroundedAt)
    }
  }

  func enteredBackground() {
    state.withLock { $0.isInBackground = true }
  }

  func enteredForeground(at now: ContinuousClock.Instant = .now) {
    state.withLock {
      $0.isInBackground = false
      $0.foregroundedAt = now
    }
  }
}
