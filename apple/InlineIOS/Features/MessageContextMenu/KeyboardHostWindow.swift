import UIKit

/// The window that hosts the system keyboard, so the context menu can draw over the keyboard
/// the way Telegram's does.
///
/// Since iOS 16 the keyboard lives in a window of an internal keyboard scene, left out of
/// `UIWindowScene.windows` and `UIApplication.windows`, and on iOS 27 a level above every app
/// window can't cover it. UIKit reaches that window through the scene's keyboard scene delegate,
/// which is what Telegram-iOS does as of October 2026 (`internalGetKeyboardForScene:`); the older
/// `+[UIRemoteKeyboardWindow remoteKeyboardWindowForScreen:create:]` traps in apps built with the
/// iOS 27 SDK.
///
/// This is private API. Every step is checked, and it returns nil when the keyboard window isn't
/// there (no keyboard yet, or the keyboard hosted out of process); the menu then puts the
/// keyboard away instead.
enum KeyboardHostWindow {
  /// The keyboard's window in `sourceWindow`'s scene, if it covers the same screen area, so the
  /// menu laid out for `sourceWindow` fits in it.
  static func find(covering sourceWindow: UIWindow) -> UIWindow? {
    guard let scene = sourceWindow.windowScene, let window = find(in: scene),
          abs(window.bounds.width - sourceWindow.bounds.width) < 1,
          abs(window.bounds.height - sourceWindow.bounds.height) < 1
    else { return nil }
    return window
  }

  static func find(in scene: UIWindowScene) -> UIWindow? {
    let delegateSelector = NSSelectorFromString("keyboardSceneDelegate")
    guard scene.responds(to: delegateSelector),
          let delegate = scene.perform(delegateSelector)?.takeUnretainedValue() as? NSObject
    else { return nil }
    let windowSelector = NSSelectorFromString("keyboardWindow")
    guard delegate.responds(to: windowSelector),
          let window = delegate.perform(windowSelector)?.takeUnretainedValue() as? UIWindow,
          !window.isHidden, window.bounds.width > 0, window.bounds.height > 0
    else { return nil }
    return window
  }
}
