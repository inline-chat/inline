import Foundation
import InlineGrid

/// Keeps a Mac in a Grid room present: no App Nap, so the presence heartbeat
/// keeps its cadence, and no idle sleep, so staying in a room (alone or not)
/// never pushes the user out. Closing the lid still sleeps the Mac; that is
/// an explicit choice and its presence then lapses like any offline client.
@MainActor
final class GridSleepGuard {
  private static var started: GridSleepGuard?

  private let store: GridRoomService
  private var activity: NSObjectProtocol?

  static func start(store: GridRoomService) {
    guard started == nil else { return }
    started = GridSleepGuard(store: store)
  }

  private init(store: GridRoomService) {
    self.store = store
    observe()
  }

  private func observe() {
    withObservationTracking {
      apply(inRoom: store.hasLocalAdmission)
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        self?.observe()
      }
    }
  }

  private func apply(inRoom: Bool) {
    if inRoom, activity == nil {
      activity = ProcessInfo.processInfo.beginActivity(
        options: .userInitiated,
        reason: "In a Grid room"
      )
    } else if !inRoom, let activity {
      ProcessInfo.processInfo.endActivity(activity)
      self.activity = nil
    }
  }
}
