import AppKit
import InlineKit

/// Opens `inline.chat` chat, public space, and invite links in this app.
/// macOS only hands universal links to apps from Safari, so without this a
/// chat link clicked inside Inline lands in a non-Safari default browser.
enum InlineWebLinkOpener {
  /// Opens `url` in Inline when it is an Inline web link, otherwise with the default app.
  @MainActor @discardableResult
  static func open(_ url: URL) -> Bool {
    if openInApp(url) { return true }
    return NSWorkspace.shared.open(url)
  }

  /// Routes an Inline web link through the app's URL handler. Returns false for any other URL.
  @MainActor
  static func openInApp(_ url: URL) -> Bool {
    guard let deepLink = InlineDeepLink(universalLink: url),
          let appURL = deepLink.url(),
          let appDelegate = NSApp.delegate as? AppDelegate
    else { return false }
    appDelegate.application(NSApp, open: [appURL])
    return true
  }
}
