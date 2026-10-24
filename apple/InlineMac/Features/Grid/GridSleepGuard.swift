import Foundation
import InlineGrid

/// Keeps Grid presence honest on macOS.
///
/// - In a room: opt out of App Nap so the presence heartbeat keeps its
///   cadence, but allow idle sleep. A Mac left alone in a room can still
///   sleep, and its presence then lapses instead of lingering forever.
/// - With live media (someone else is in the room): also prevent idle sleep,
///   so an active call never drops because the desk went quiet.
///
/// Closing the lid still sleeps the Mac; that is an explicit user choice.
@MainActor
final class GridSleepGuard {
  private enum Level: Equatable {
    case none
    case inRoom
    case inCall

    var options: ProcessInfo.ActivityOptions? {
      switch self {
        case .none: nil
        case .inRoom: .userInitiatedAllowingIdleSystemSleep
        case .inCall: .userInitiated
      }
    }
  }

  private static var started: GridSleepGuard?

  private let store: GridRoomService
  private var level = Level.none
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
      let inRoom = store.hasLocalAdmission
      let mediaLive = store.media.connectionState != .disconnected
      apply(inRoom ? (mediaLive ? .inCall : .inRoom) : .none)
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        self?.observe()
      }
    }
  }

  private func apply(_ next: Level) {
    guard next != level else { return }
    if let activity {
      ProcessInfo.processInfo.endActivity(activity)
      self.activity = nil
    }
    level = next
    if let options = next.options {
      activity = ProcessInfo.processInfo.beginActivity(
        options: options,
        reason: next == .inCall ? "In a Grid call" : "In a Grid room"
      )
    }
  }
}
