import InlineIOSUI
import Logger
import UIKit

/// Picks the message menu for a chat and keeps the custom menu's rollout safe: a crash guard
/// that falls back to UIKit's menu, breadcrumbs for Sentry, and UIKit's menu under VoiceOver.
@MainActor
enum MessageContextMenuRollout {
  static let log = Log.scoped("MessageContextMenu")

  /// The menu a new chat uses. Chat previews keep UIKit's menu; the custom one presents over
  /// the whole window.
  static func implementation(isPreview: Bool) -> MessageContextMenuImplementation {
    _ = launchCheck
    return MessageContextMenuFeature.selectedImplementation(isAvailable: !isPreview)
  }

  /// UIKit's menu stands in while VoiceOver runs: it comes with the rotor's menu action, and
  /// a hold reaches the custom menu's gesture only as a pass-through.
  static var prefersSystemMenuNow: Bool {
    UIAccessibility.isVoiceOverRunning
  }

  /// The menu went on screen.
  static func didPresent(overKeyboard: Bool, livePreview: Bool, selectableText: Bool) {
    MessageContextMenuFeature.markOpen()
    log.info(
      "custom menu opened overKeyboard=\(overKeyboard) live=\(livePreview) selectable=\(selectableText)"
    )
  }

  static func didDismiss() {
    MessageContextMenuFeature.markClosed()
  }

  /// A hold reached the menu but it couldn't open.
  static func didFailToPresent(reason: String) {
    log.warning("custom menu failed to open: \(reason)")
  }

  /// A chat gave up on the custom menu after repeated failures.
  static func didFallBack(reason: String) {
    log.error("custom menu fell back to the system menu: \(reason)")
  }

  /// Runs once per process, before the first chat picks its menu.
  private static let launchCheck: Void = {
    switch MessageContextMenuFeature.checkLastRun() {
    case .clean:
      break
    case let .strike(count):
      log.warning("last run ended with the custom menu open (\(count) so far)")
    case let .turnedOff(count):
      log.error("custom menu turned off after \(count) runs ended with it open")
    }
    // A run killed from the app switcher with a menu still up isn't a crash.
    NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
    ) { _ in
      MessageContextMenuFeature.markClosed()
    }
  }()
}
