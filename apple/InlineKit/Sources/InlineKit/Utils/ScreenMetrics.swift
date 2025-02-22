

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
enum ScreenMetrics {
  static var height: CGFloat? {
    #if os(iOS) || os(tvOS)
    // Get main screen bounds for iOS/tvOS
    return UIScreen.main.bounds.height
    #elseif os(macOS)
    // Get main window height for macOS
    if let window = NSApplication.shared.mainWindow {
      return window.frame.height
    }
    // Fallback to screen height if no window is available
    return NSScreen.main?.frame.height
    #endif
  }
}
