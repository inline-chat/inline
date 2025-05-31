import AppKit
import Foundation
import ObjectiveC

/*
 Simple Custom Tooltip System

 This provides a clean, unified tooltip experience across the app with:
 - Automatic light/dark mode adaptation
 - Beautiful animations and shadows
 - Consistent styling throughout the app
 - Child window attachment for proper app switcher behavior
 - Configurable styling constants
 - Smart delay skipping when moving between tooltips

 Usage:
 ```swift
 // Show tooltip
 SimpleTooltip.shared.show(text: "Tooltip text", near: view)

 // Hide tooltip
 SimpleTooltip.shared.hide()
 ```
 */

// MARK: - Tooltip Configuration

enum TooltipConfig {
  // MARK: - Timing

  static let showDelay: TimeInterval = 1.0
  static let hideDelay: TimeInterval = 0.01
  static let animationShowDuration: TimeInterval = 0.15
  static let animationHideDuration: TimeInterval = 0.15
  static let quickShowDelay: TimeInterval = 0.3 // When moving between tooltips

  // MARK: - Sizing & Spacing

  static let contentPaddingHorizontal: CGFloat = 8
  static let contentPaddingVertical: CGFloat = 6
  static let shadowPadding: CGFloat = 6
  static let maxWidth: CGFloat = 200
  static let cornerRadius: CGFloat = 10
  static let distanceFromView: CGFloat = 2
  static let screenMargin: CGFloat = 8

  // MARK: - Typography

  static let fontSize: CGFloat = 12
  static let fontWeight: NSFont.Weight = .medium

  // MARK: - Visual Effects

  static let borderWidth: CGFloat = 1
  static let shadowRadius: CGFloat = 4
  static let shadowOffset = NSSize(width: 0, height: -2)
  static let innerBorderWidth: CGFloat = 1

  // MARK: - Opacity Values

  static let backgroundOpacityLight: CGFloat = 0.9
  static let backgroundOpacityDark: CGFloat = 0.95
  static let shadowOpacityLight: Float = 0.25
  static let shadowOpacityDark: Float = 0.4
  static let borderOpacityLight: CGFloat = 0.3
  static let borderOpacityDark: CGFloat = 0.4
  static let overlayOpacityLight: CGFloat = 0.02
  static let overlayOpacityDark: CGFloat = 0.03
  static let innerBorderOpacityLight: CGFloat = 0.15
  static let innerBorderOpacityDark: CGFloat = 0.08

  // MARK: - Animation

  static let scaleFrom: CGFloat = 0.95
  static let scaleTo: CGFloat = 1.0
  static let scaleHideTo: CGFloat = 0.95
  static let animationControlPoints = (0.34, 1.56, 0.64, 1.0) // Custom ease-out with slight overshoot
}

// MARK: - Simple Custom Tooltip

class SimpleTooltip {
  static let shared = SimpleTooltip()

  private var tooltipWindow: NSWindow?
  private var parentWindow: NSWindow?
  private var showTimer: Timer?
  private var hideTimer: Timer?
  private var lastTooltipTime: Date?
  private var isTooltipVisible = false
  private var scrollEventMonitor: Any?
  private var windowEventMonitor: Any?

  /// Used to disable tooltips while scrolling
  private var isScrolling = false

  private init() {
    // Listen for appearance changes
    DistributedNotificationCenter.default.addObserver(
      self,
      selector: #selector(appearanceChanged),
      name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
      object: nil
    )

    setupScrollEventMonitoring()
  }

  deinit {
    DistributedNotificationCenter.default.removeObserver(self)
    cleanupScrollEventMonitoring()
  }

  // MARK: - Scroll Event Monitoring

  private func setupScrollEventMonitoring() {
    // Also listen for scroll view notifications
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(scrollViewDidEndScroll),
      name: NSScrollView.didEndLiveScrollNotification,
      object: nil
    )

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(scrollViewDidStartScroll),
      name: NSScrollView.willStartLiveScrollNotification,
      object: nil
    )
  }

  private func setupWindowEventMonitoring(for window: NSWindow) {
    // Monitor scroll events at the window level
    // windowEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
    //   print("scrollWheel")
    //   if event.window == window, self?.isTooltipVisible == true {
    //     self?.hideImmediately()
    //   }
    //   return event
    // }
  }

  @objc private func scrollViewDidStartScroll() {
    isScrolling = true
    print("scrollViewDidStartScroll")
    if isTooltipVisible {
      hideImmediately()
    }
  }

  @objc private func scrollViewDidEndScroll() {
    isScrolling = false
    print("scrollViewDidEndScroll")
    if isTooltipVisible {
      hideImmediately()
    }
  }

  private func cleanupScrollEventMonitoring() {
    if let monitor = scrollEventMonitor {
      NSEvent.removeMonitor(monitor)
      scrollEventMonitor = nil
    }

    if let monitor = windowEventMonitor {
      NSEvent.removeMonitor(monitor)
      windowEventMonitor = nil
    }

    NotificationCenter.default.removeObserver(self, name: NSScrollView.didLiveScrollNotification, object: nil)
    NotificationCenter.default.removeObserver(self, name: NSScrollView.willStartLiveScrollNotification, object: nil)
  }

  @objc private func appearanceChanged() {
    // If a tooltip is currently showing, hide it so it can be reshown with new appearance
    if tooltipWindow != nil {
      hideImmediately()
    }
  }

  // MARK: - Public API

  func show(text: String, near view: NSView) {
    if isScrolling {
      return
    }

    showTimer?.invalidate()

    // Determine if we should use quick show delay (when moving between tooltips)
    let shouldUseQuickDelay = shouldSkipDelay()
    let delay = shouldUseQuickDelay ? TooltipConfig.quickShowDelay : TooltipConfig.showDelay

    hideImmediately() // Always hide any existing tooltip first

    showTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
      self?.createAndShowTooltip(text: text, near: view)
    }
  }

  func hide() {
    showTimer?.invalidate()
    hideTimer?.invalidate()

    guard let window = tooltipWindow else { return }

    hideTimer = Timer.scheduledTimer(withTimeInterval: TooltipConfig.hideDelay, repeats: false) { [weak self] _ in
      self?.dismissTooltip()
    }
  }

  func hideImmediately() {
    showTimer?.invalidate()
    hideTimer?.invalidate()
    dismissTooltip()
    lastTooltipTime = nil
  }

  // MARK: - Smart Delay Logic

  private func shouldSkipDelay() -> Bool {
    guard let lastTime = lastTooltipTime else { return false }
    let timeSinceLastTooltip = Date().timeIntervalSince(lastTime)
    if isScrolling {
      return false
    }
    // If less than 2 seconds since last tooltip, use quick delay
    return timeSinceLastTooltip < 1.0
  }

  // MARK: - Private Implementation

  private func createAndShowTooltip(text: String, near view: NSView) {
    guard let viewWindow = view.window,
          !text.isEmpty else { return }

    // Get current appearance for adaptive styling
    let isDarkMode = NSApp.effectiveAppearance.isDarkMode

    // Create tooltip content with NSTextView for better text handling
    let textView = NSTextView()
    textView.string = text
    textView.font = NSFont.systemFont(ofSize: TooltipConfig.fontSize, weight: TooltipConfig.fontWeight)
    textView.textColor = .labelColor
    textView.backgroundColor = .clear
    textView.isEditable = false
    textView.isSelectable = false
    textView.isRichText = false
    textView.drawsBackground = false

    // Configure text container for proper wrapping
    let textContainer = textView.textContainer!
    textContainer.containerSize = NSSize(width: TooltipConfig.maxWidth, height: CGFloat.greatestFiniteMagnitude)
    textContainer.widthTracksTextView = false
    textContainer.heightTracksTextView = false
    textContainer.lineFragmentPadding = 0

    // Force layout to calculate proper size
    textView.layoutManager?.ensureLayout(for: textContainer)

    // Get the actual size needed for the text
    let usedRect = textView.layoutManager!.usedRect(for: textContainer)
    let textSize = NSSize(
      width: ceil(usedRect.width),
      height: ceil(usedRect.height)
    )

    // Ensure minimum size
    guard textSize.width > 0, textSize.height > 0 else { return }

    // Set the text view frame to the calculated size
    textView.frame = NSRect(origin: .zero, size: textSize)

    // Create container view with padding
    let containerSize = NSSize(
      width: textSize.width + TooltipConfig.contentPaddingHorizontal * 2,
      height: textSize.height + TooltipConfig.contentPaddingVertical * 2
    )

    // Add extra space for shadow (so it doesn't get clipped)
    let windowSize = NSSize(
      width: containerSize.width + TooltipConfig.shadowPadding * 2,
      height: containerSize.height + TooltipConfig.shadowPadding * 2
    )

    // Create the main container view with material blur background
    let containerView = NSVisualEffectView(frame: NSRect(
      x: TooltipConfig.shadowPadding,
      y: TooltipConfig.shadowPadding,
      width: containerSize.width,
      height: containerSize.height
    ))

    // Configure material blur effect
    containerView.material = isDarkMode ? .hudWindow : .popover
    containerView.blendingMode = .behindWindow
    containerView.state = .active
    containerView.wantsLayer = true

    // Create wrapper view for the window content (transparent, just holds the container)
    let wrapperView = NSView(frame: NSRect(origin: .zero, size: windowSize))
    wrapperView.addSubview(containerView)

    // Style the container
    guard let layer = containerView.layer else { return }

    // Apply corner radius and masking
    layer.cornerRadius = TooltipConfig.cornerRadius
    layer.masksToBounds = true // This ensures the blur respects corner radius

    // Apply shadow to wrapper view instead to avoid clipping
    if let wrapperLayer = wrapperView.layer {
      wrapperView.wantsLayer = true
      wrapperLayer.shadowColor = NSColor.black.cgColor
      wrapperLayer.shadowOpacity = isDarkMode ? TooltipConfig.shadowOpacityDark : TooltipConfig.shadowOpacityLight
      wrapperLayer.shadowOffset = TooltipConfig.shadowOffset
      wrapperLayer.shadowRadius = TooltipConfig.shadowRadius
      wrapperLayer.shadowPath = CGPath(
        roundedRect: containerView.frame,
        cornerWidth: TooltipConfig.cornerRadius,
        cornerHeight: TooltipConfig.cornerRadius,
        transform: nil
      )
    }

    // Subtle overall glow overlay for glass effect
    let glassOverlay = CAGradientLayer()
    glassOverlay.frame = layer.bounds
    glassOverlay.cornerRadius = TooltipConfig.cornerRadius
    glassOverlay.colors = [
      NSColor.white.withAlphaComponent(isDarkMode ? 0.08 : 0.12).cgColor,
      NSColor.white.withAlphaComponent(isDarkMode ? 0.02 : 0.04).cgColor,
      NSColor.clear.cgColor,
    ]
    glassOverlay.locations = [0.0, 0.5, 1.0]
    glassOverlay.startPoint = CGPoint(x: 0.5, y: 0.0)
    glassOverlay.endPoint = CGPoint(x: 0.5, y: 1.0)

    layer.addSublayer(glassOverlay)

    // Add a simple light border
    layer.borderWidth = TooltipConfig.borderWidth
    layer.borderColor = NSColor.white.withAlphaComponent(isDarkMode ? 0.1 : 0.1).cgColor

    // Position label in container
    textView.frame = NSRect(
      x: TooltipConfig.contentPaddingHorizontal,
      y: TooltipConfig.contentPaddingVertical,
      width: textSize.width,
      height: textSize.height
    )
    containerView.addSubview(textView)

    // Create tooltip window as a child window
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: windowSize),
      styleMask: [],
      backing: .buffered,
      defer: false
    )

    window.contentView = wrapperView
    window.isOpaque = false
    window.backgroundColor = NSColor.clear
    window.hasShadow = false // We handle shadows ourselves
    window.level = NSWindow.Level.floating
    window.ignoresMouseEvents = true
    window.collectionBehavior = [.canJoinAllSpaces, .stationary]

    // Calculate position (account for the extra shadow padding)
    let viewBounds = view.bounds
    let viewFrameInWindow = view.convert(viewBounds, to: nil)
    let viewFrameOnScreen = viewWindow.convertToScreen(viewFrameInWindow)

    // Position above the view (adjust for shadow padding)
    let tooltipX = viewFrameOnScreen.midX - windowSize.width / 2
    let tooltipY = viewFrameOnScreen.maxY + TooltipConfig.distanceFromView

    // Keep on screen
    let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_920, height: 1_080)
    let adjustedX = max(
      screen.minX + TooltipConfig.screenMargin,
      min(tooltipX, screen.maxX - windowSize.width - TooltipConfig.screenMargin)
    )
    let adjustedY = min(tooltipY, screen.maxY - windowSize.height - TooltipConfig.screenMargin)

    window.setFrameOrigin(NSPoint(x: adjustedX, y: adjustedY))

    // Make it a child window for proper app switcher behavior
    viewWindow.addChildWindow(window, ordered: .above)

    // Store references
    tooltipWindow = window
    parentWindow = viewWindow
    isTooltipVisible = true
    lastTooltipTime = Date()

    // Setup window-specific event monitoring
    setupWindowEventMonitoring(for: viewWindow)

    // Show with smooth combined scale + opacity animation
    window.alphaValue = 0
    containerView.layer?.transform = CATransform3DMakeScale(TooltipConfig.scaleFrom, TooltipConfig.scaleFrom, 1.0)
    window.orderFront(nil)

    // Create smooth combined animation
    let animationGroup = CAAnimationGroup()
    animationGroup.duration = TooltipConfig.animationShowDuration
    animationGroup.timingFunction = CAMediaTimingFunction(
      controlPoints: Float(TooltipConfig.animationControlPoints.0),
      Float(TooltipConfig.animationControlPoints.1),
      Float(TooltipConfig.animationControlPoints.2),
      Float(TooltipConfig.animationControlPoints.3)
    )

    // Scale animation
    let scaleAnimation = CABasicAnimation(keyPath: "transform")
    scaleAnimation.fromValue = CATransform3DMakeScale(TooltipConfig.scaleFrom, TooltipConfig.scaleFrom, 1.0)
    scaleAnimation.toValue = CATransform3DIdentity

    // Opacity animation for the container
    let opacityAnimation = CABasicAnimation(keyPath: "opacity")
    opacityAnimation.fromValue = 0.0
    opacityAnimation.toValue = 1.0

    animationGroup.animations = [scaleAnimation, opacityAnimation]
    animationGroup.fillMode = .forwards
    animationGroup.isRemovedOnCompletion = false

    // Apply final state immediately to prevent jumps
    containerView.layer?.transform = CATransform3DIdentity
    containerView.layer?.opacity = 1.0
    window.alphaValue = 1.0

    // Run the animation
    containerView.layer?.add(animationGroup, forKey: "showAnimation")
  }

  private func dismissTooltip() {
    guard let window = tooltipWindow else { return }

    // Get the container view for scale animation
    let containerView = (window.contentView?.subviews.first)

    NSAnimationContext.runAnimationGroup({ context in
      context.duration = TooltipConfig.animationHideDuration
      context.timingFunction = CAMediaTimingFunction(name: .easeIn)
      context.allowsImplicitAnimation = true

      // Animate opacity
      window.animator().alphaValue = 0

      // Animate scale down
      containerView?.layer?.transform = CATransform3DMakeScale(
        TooltipConfig.scaleHideTo,
        TooltipConfig.scaleHideTo,
        1.0
      )

    }, completionHandler: { [weak self] in
      // Remove from parent window and clean up
      if let parent = self?.parentWindow {
        parent.removeChildWindow(window)
      }
      window.orderOut(nil)
      self?.isTooltipVisible = false

      // Cleanup window event monitoring
      if let monitor = self?.windowEventMonitor {
        NSEvent.removeMonitor(monitor)
        self?.windowEventMonitor = nil
      }
    })

    tooltipWindow = nil
    parentWindow = nil
  }
}

// MARK: - NSView Extension

extension NSView {
  private static var tooltipTextKey: UInt8 = 0

  private var storedTooltipText: String? {
    get {
      objc_getAssociatedObject(self, &Self.tooltipTextKey) as? String
    }
    set {
      objc_setAssociatedObject(self, &Self.tooltipTextKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
  }

  func setCustomTooltip(_ text: String) {
    storedTooltipText = text
  }

  func showCustomTooltip() {
    if let text = storedTooltipText, !text.isEmpty {
      SimpleTooltip.shared.show(text: text, near: self)
    }
  }

  func removeCustomTooltip() {
    storedTooltipText = nil
    SimpleTooltip.shared.hide()
  }
}

// MARK: - NSBezierPath Extension for CGPath Compatibility

extension NSBezierPath {
  var compatibleCGPath: CGPath {
    let path = CGMutablePath()
    var points = [CGPoint](repeating: .zero, count: 3)

    for i in 0 ..< elementCount {
      let type = element(at: i, associatedPoints: &points)
      switch type {
        case .moveTo:
          path.move(to: points[0])
        case .lineTo:
          path.addLine(to: points[0])
        case .curveTo:
          path.addCurve(to: points[2], control1: points[0], control2: points[1])
        case .closePath:
          path.closeSubpath()
        @unknown default:
          break
      }
    }
    return path
  }
}
