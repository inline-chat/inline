#if canImport(UIKit)
import QuartzCore
import TimelineCore
import UIKit

/// Every private touch point of the system keyboard, in one place.
///
/// The public interactive dismissal cannot be followed smoothly on iOS 27 (on release the keyboard
/// vanishes within two frames), so the keyboard's own host view is moved instead, in the same
/// transaction as the composer and the list. Measured on an iPhone SE, iOS 27.2: within a point on
/// video during the drag, on release and on cancel.
///
/// Nothing here is required: when the lookup fails or the switch is off, `KeyboardHost` is nil and
/// callers fall back to a keyboard that is only dismissed by a tap.
@MainActor
struct KeyboardHost {
  /// Set this default to turn every private keyboard touch point off.
  static let disabledKey = "timeline.keyboardHost.disabled"

  private let view: UIView

  /// The keyboard of this scene, while it is on screen.
  init?(scene: UIWindowScene?) {
    guard !UserDefaults.standard.bool(forKey: Self.disabledKey), let scene else { return nil }
    // scene.keyboardSceneDelegate.keyboardWindow → …InputSetContainerView → …InputSetHostView
    var windows: [UIWindow] = []
    if let delegate = Self.object(scene, ["keyboard", "Scene", "Delegate"]),
       let window = Self.object(delegate, ["keyboard", "Window"]) as? UIWindow
    {
      windows.append(window)
    }
    // iOS 15–16 have no keyboard scene: the keyboard lives in the scene's remote-keyboard or
    // text-effects window.
    // Like Telegram's fallback: every connected window scene's windows, plus the app's.
    let sceneWindows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
    windows += (scene.windows + sceneWindows + UIApplication.shared.windows).filter { window in
      let name = NSStringFromClass(type(of: window))
      return name.hasSuffix("RemoteKeyboardWindow") || name.hasSuffix("TextEffectsWindow")
    }
    var found: UIView?
    for window in windows {
      // Container/host names vary by release (Telegram checks the same pairs).
      for container in window.subviews {
        let containerName = NSStringFromClass(type(of: container))
        guard containerName.hasSuffix("InputSetContainerView") || containerName.hasSuffix("TrackingWindowView") else { continue }
        if let host = container.subviews.first(where: {
          let name = NSStringFromClass(type(of: $0))
          return name.hasSuffix("InputSetHostView") || name.hasSuffix("KeyboardItemContainerView")
        }), host.bounds.height > 0 {
          found = host
          break
        }
      }
      if found != nil { break }
    }
    guard let found else { return nil }
    view = found
  }

  private static func object(_ target: NSObject, _ name: [String]) -> NSObject? {
    let selector = NSSelectorFromString(name.joined())
    guard target.responds(to: selector) else { return nil }
    return target.perform(selector)?.takeUnretainedValue() as? NSObject
  }

  var height: CGFloat { view.bounds.height }

  /// Moves the keyboard down by `offset` points, at once.
  func setOffset(_ offset: CGFloat) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    view.layer.transform = CATransform3DMakeTranslation(0, offset, 0)
    CATransaction.commit()
  }

  /// Moves the keyboard to `offset` with a track that starts where it was.
  func setOffset(_ offset: CGFloat, from previous: CGFloat, timing: TimelineTiming) {
    setOffset(offset)
    view.layer.addTrack(timing, keyPath: "transform.translation.y", from: previous - offset)
  }

  /// Puts the keyboard back as the system left it and drops what is still animating in its window.
  func restore() {
    func stop(_ view: UIView) {
      view.layer.removeAllAnimations()
      view.subviews.forEach(stop)
    }
    view.window?.subviews.forEach(stop)
    setOffset(0)
  }
}
#endif
