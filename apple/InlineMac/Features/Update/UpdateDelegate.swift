#if SPARKLE
import AppKit
import Logger
import Sparkle

final class UpdateDelegate: NSObject, SPUUpdaterDelegate {
  private let log = Log.scoped("UpdateDelegate")

  func feedURLString(for _: SPUUpdater) -> String? {
    switch AppSettings.shared.autoUpdateChannel {
    case .beta:
      let url = "https://public-assets.inline.chat/mac/beta/appcast.xml"
      log.info("Using beta appcast: \(url)")
      return url
    case .stable:
      let url = "https://public-assets.inline.chat/mac/stable/appcast.xml"
      log.info("Using stable appcast: \(url)")
      return url
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
