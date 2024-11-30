import AppKit
import InlineConfig
import Sentry
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationWillFinishLaunching(_ notification: Notification) {
    // Disable native tabbing
    NSWindow.allowsAutomaticWindowTabbing = false
  }

  func applicationDidFinishLaunching(_ aNotification: Notification) {
    SentrySDK.start { options in
      options.dsn = InlineConfig.SentryDSN
      options.debug = false
      options.tracesSampleRate = 0.1
    }
  }

  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
