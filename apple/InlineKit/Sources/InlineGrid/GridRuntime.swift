import Foundation
import InlineKit
import InlineRTC
import RealtimeV2

/// One authenticated-process owner for Grid's product, RTC, and audio domains.
/// `AppDependencies` is copied per window, but this reference is shared.
@MainActor
public final class GridRuntime {
  private static var cachedRuntime: GridRuntime?

  public static var shared: GridRuntime {
    if let cachedRuntime {
      return cachedRuntime
    }
    let runtime = GridRuntime()
    cachedRuntime = runtime
    return runtime
  }

  /// Feature-off and logout teardown can inspect the owner without creating
  /// media engines for a process that has never opened Grid.
  public static var existing: GridRuntime? {
    cachedRuntime
  }

  private let engine: InlineRTCSession
  public let rooms: GridRoomService

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

  public func configurePlatformEffects(_ effects: GridPlatformEffects) {
    rooms.configurePlatformEffects(effects)
  }

  public func prepareForLogout() async -> GridMediaShutdownReceipt {
    await rooms.prepareForLogout()
    return await engine.shutdown()
  }

  public func applicationDidWake() async {
    await rooms.applicationDidWake()
  }
}
