#if SPARKLE
import AppKit
import Sparkle

final class UpdateDelegate: NSObject, SPUUpdaterDelegate {
  func feedURLString(for _: SPUUpdater) -> String? {
    switch AppSettings.shared.autoUpdateChannel {
    case .beta:
      return "https://public-assets.inline.chat/mac/beta/appcast.xml"
    case .stable:
      return "https://public-assets.inline.chat/mac/stable/appcast.xml"
    }
  }

  func updaterWillRelaunchApplication(_: SPUUpdater) {
    NSApp.invalidateRestorableState()
    for window in NSApp.windows {
      window.invalidateRestorableState()
    }
  }
}
#endif
