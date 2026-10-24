import InlineGrid
import UIKit

/// The process-owned Grid runtime with iOS platform effects installed once.
/// Use this instead of `GridRuntime.shared` in the iOS app.
@MainActor
enum GridIOSRuntime {
  private static var isConfigured = false

  static var shared: GridRuntime {
    let runtime = GridRuntime.shared
    if !isConfigured {
      isConfigured = true
      var effects = GridPlatformEffects()
      effects.isApplicationActive = { UIApplication.shared.applicationState == .active }
      runtime.configurePlatformEffects(effects)
    }
    return runtime
  }
}
