import AudioToolbox
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
      effects.playSound = { GridIOSSoundEffects.play($0) }
      runtime.configurePlatformEffects(effects)
    }
    return runtime
  }
}

/// The Mac's join, leave and connected cues. System sounds mix with other
/// audio, follow the silent switch and never touch the audio session that
/// Grid owns. The files carry the Mac's playback volume.
@MainActor
private enum GridIOSSoundEffects {
  private static var soundIDs: [GridPlatformEffects.Sound: SystemSoundID] = [:]

  static func play(_ sound: GridPlatformEffects.Sound) {
    guard let soundID = soundID(for: sound) else { return }
    AudioServicesPlaySystemSound(soundID)
  }

  private static func soundID(for sound: GridPlatformEffects.Sound) -> SystemSoundID? {
    if let soundID = soundIDs[sound] {
      return soundID
    }
    let name = switch sound {
      case .join: "grid-maybe-join"
      case .leave: "grid-unlock"
      case .connected: "grid-connected2"
    }
    var soundID: SystemSoundID = 0
    guard let url = Bundle.main.url(forResource: name, withExtension: "caf"),
          AudioServicesCreateSystemSoundID(url as CFURL, &soundID) == kAudioServicesNoError
    else { return nil }
    soundIDs[sound] = soundID
    return soundID
  }
}
