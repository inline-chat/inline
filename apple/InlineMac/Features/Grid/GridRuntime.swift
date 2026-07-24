import Foundation
import InlineKit
import InlineRTC
import RealtimeV2

/// One authenticated-process owner for Grid's product, RTC, and audio domains.
/// `AppDependencies` is copied per window, but this reference is shared.
@MainActor
final class GridRuntime {
  static let shared = GridRuntime()

  private let engine: InlineRTCSession
  let rooms: GridRoomService

  private init(
    realtime: RealtimeV2 = Api.realtime,
    userDefaults: UserDefaults = .standard
  ) {
    let engine = InlineRTCSession()
    self.engine = engine
    rooms = GridRoomService(
      realtime: realtime,
      userDefaults: userDefaults,
      engine: engine
    )
  }

  func prepareForLogout() async -> GridMediaShutdownReceipt {
    await rooms.prepareForLogout()
    return await engine.shutdown()
  }

  func applicationDidWake() async {
    await rooms.applicationDidWake()
  }
}
