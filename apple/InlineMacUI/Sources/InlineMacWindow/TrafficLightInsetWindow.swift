import AppKit

@MainActor
public protocol TrafficLightInsetApplicable: AnyObject {
  func applyTrafficLightsInset()
}

@MainActor
open class TrafficLightInsetWindow: NSWindow, TrafficLightInsetApplicable {
  public var trafficLightsInset = CGPoint(x: 20, y: 16)
  private var isApplyingTrafficLights = false

  public func applyTrafficLightsInset() {
    if isApplyingTrafficLights { return }
    guard let close = standardWindowButton(.closeButton),
          let miniaturize = standardWindowButton(.miniaturizeButton),
          let zoom = standardWindowButton(.zoomButton),
          let titleBarContainer = close.superview?.superview
    else {
      return
    }

    let closeRect = close.frame
    // Tao sets titlebar height = button height + y. To make `trafficLightsInset.y`
    // represent the actual top inset to the button, account for the button's own origin.
    let effectiveY = trafficLightsInset.y + closeRect.origin.y
    let titleBarHeight = closeRect.size.height + effectiveY
    var titleBarRect = titleBarContainer.frame
    titleBarRect.size.height = titleBarHeight
    titleBarRect.origin.y = frame.size.height - titleBarHeight

    let spaceBetween = miniaturize.frame.origin.x - closeRect.origin.x
    let desiredCloseX = trafficLightsInset.x
    let desiredMiniX = trafficLightsInset.x + spaceBetween
    let desiredZoomX = trafficLightsInset.x + 2 * spaceBetween

    func nearlyEqual(_ a: CGFloat, _ b: CGFloat, tolerance: CGFloat = 0.5) -> Bool {
      abs(a - b) <= tolerance
    }

    let titlebarMatches = nearlyEqual(titleBarContainer.frame.size.height, titleBarRect.size.height)
      && nearlyEqual(titleBarContainer.frame.origin.y, titleBarRect.origin.y)
    let buttonsMatch = nearlyEqual(close.frame.origin.x, desiredCloseX)
      && nearlyEqual(miniaturize.frame.origin.x, desiredMiniX)
      && nearlyEqual(zoom.frame.origin.x, desiredZoomX)

    if titlebarMatches && buttonsMatch {
      return
    }

    isApplyingTrafficLights = true
    defer { isApplyingTrafficLights = false }

    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0
      context.allowsImplicitAnimation = false
      titleBarContainer.frame = titleBarRect

      close.setFrameOrigin(NSPoint(x: desiredCloseX, y: close.frame.origin.y))
      miniaturize.setFrameOrigin(NSPoint(x: desiredMiniX, y: miniaturize.frame.origin.y))
      zoom.setFrameOrigin(NSPoint(x: desiredZoomX, y: zoom.frame.origin.y))
    }
  }
}
