import AppKit
import InlineKit
import InlineUI
import Logger
import SwiftUI

class MessageTimeAndState: NSView {
  private var fullMessage: FullMessage
  private var currentState: MessageSendingStatus = .sent
  private var tooltipText: String = ""
  private var trackingArea: NSTrackingArea?

  private var isOverlay: Bool {
    fullMessage.message.text == nil || fullMessage.message.text?.isEmpty == true
  }

  private var textColor: NSColor {
    if isOverlay {
      .white.withAlphaComponent(0.8)
    } else {
      fullMessage.message.out == true ? .white.withAlphaComponent(0.5) : .tertiaryLabelColor
    }
  }

  private var hasSymbol: Bool {
    fullMessage.message.out == true
  }

  private var isFailedMessage: Bool {
    fullMessage.message.status == .failed
  }

  // MARK: - Layer Setup

  // Improved cache with scale awareness and memory management
  private static var imageCache: [CacheKey: CGImage] = [:]

  // Key struct for proper cache identity
  fileprivate struct CacheKey: Hashable {
    let status: MessageSendingStatus
    let isFailed: Bool
    let scaleFactor: CGFloat
    let isOutgoing: Bool
    let isOverlay: Bool
    let isDarkMode: Bool
  }

  // MARK: - Layer Setup (Modified)

  private lazy var timeLayer: CATextLayer = createTextLayer()
  private lazy var statusLayer: CALayer = createStatusLayer()
  private lazy var backgroundLayer: CALayer = createBackgroundLayer()

  private func createTextLayer() -> CATextLayer {
    let layer = CATextLayer()
    layer.contentsScale = effectiveScaleFactor
    layer.font = Self.font
    layer.fontSize = 10
    layer.alignmentMode = .right
    layer.truncationMode = .none
    layer.isWrapped = false
    return layer
  }

  private func createStatusLayer() -> CALayer {
    let layer = CALayer()
    layer.contentsScale = effectiveScaleFactor
    layer.masksToBounds = true
    layer.contentsGravity = .resizeAspect
    layer.minificationFilter = .trilinear
    layer.magnificationFilter = .nearest
    layer.shouldRasterize = true
    layer.rasterizationScale = effectiveScaleFactor
    return layer
  }

  private func createBackgroundLayer() -> CALayer {
    let layer = CALayer()
    layer.contentsScale = effectiveScaleFactor
    layer.cornerRadius = 6
    layer.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
    layer.isHidden = !isOverlay
    return layer
  }

  private var timeWidth: CGFloat = 0.0

  // Dynamic scale factor handling
  private var effectiveScaleFactor: CGFloat {
    window?.backingScaleFactor ?? window?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1.0
  }

  // MARK: - Image Generation (Improved)

  private func createStatusImage() -> CGImage? {
    let status = fullMessage.message.status ?? .sent
    let color = isFailedMessage ? NSColor.systemRed : textColor
    let scale = effectiveScaleFactor
    let cacheKey = CacheKey(
      status: status,
      isFailed: isFailedMessage,
      scaleFactor: scale,
      isOutgoing: fullMessage.message.out ?? false,
      isOverlay: isOverlay,
      isDarkMode: NSApp.effectiveAppearance.isDarkMode
    )

    if let cached = Self.imageCache[cacheKey] {
      return cached
    }

    let symbolName = switch status {
      case .sent: "checkmark"
      case .sending: "clock"
      case .failed: "exclamationmark.triangle"
    }

    let config = NSImage.SymbolConfiguration(
      pointSize: Self.symbolWidth * scale, // Scale the point size
      weight: .bold,
      scale: .small
    )
    .applying(.init(paletteColors: [color]))

    let symbolImage = NSImage(
      systemSymbolName: symbolName,
      accessibilityDescription: nil
    )?
      .withSymbolConfiguration(config)

    // Create a new image with the correct dimensions
    let size = CGSize(width: Self.symbolWidth * scale, height: Self.symbolWidth * scale)
    let newImage = NSImage(size: size)

    newImage.lockFocus()
    if let symbolImage {
      symbolImage.draw(
        in: CGRect(origin: .zero, size: size),
        from: .zero,
        operation: .sourceOver,
        fraction: 1.0
      )
    }
    newImage.unlockFocus()

    // Get the CGImage at the correct scale
    let cgImage = newImage.cgImage(forProposedRect: nil, context: nil, hints: nil)

    if let cgImage {
      Self.imageCache[cacheKey] = cgImage
    }

    return cgImage
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    updateScaleFactors()
  }

  private func updateScaleFactors() {
    let scale = effectiveScaleFactor
    timeLayer.contentsScale = scale
    statusLayer.contentsScale = scale
    statusLayer.rasterizationScale = scale
    statusLayer.contents = createStatusImage()
  }

  // MARK: - Initialization

  init(fullMessage: FullMessage) {
    self.fullMessage = fullMessage
    super.init(frame: .zero)
    configureLayerSetup()
    updateContent()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func configureLayerSetup() {
    wantsLayer = true
    layer?.masksToBounds = true
    layer?.addSublayer(backgroundLayer)
    layer?.addSublayer(timeLayer)
    layer?.addSublayer(statusLayer)
    statusLayer.isHidden = !hasSymbol
    updateTooltip()
    setupMouseTracking()
  }

  private func updateTooltip() {
    let tooltipText = Self.tooltipFormatter.string(from: fullMessage.message.date)
    self.tooltipText = tooltipText
  }

  private func setupMouseTracking() {
    updateTrackingAreas()
  }

  // MARK: - Mouse Tracking

  override func updateTrackingAreas() {
    super.updateTrackingAreas()

    if let trackingArea {
      removeTrackingArea(trackingArea)
    }

    trackingArea = NSTrackingArea(
      rect: bounds,
      options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self,
      userInfo: nil
    )

    if let trackingArea {
      addTrackingArea(trackingArea)
    }
  }

  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    if !tooltipText.isEmpty {
      SimpleTooltip.shared.show(text: tooltipText, near: self)
    }
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    SimpleTooltip.shared.hide()
  }

  // MARK: - Layout

  override func layout() {
    super.layout()

    let maxTimeWidth = Self.timeWidth
    let symbolWidth = Self.symbolWidth
    let totalWidth = maxTimeWidth + (hasSymbol ? symbolWidth : 0.0)
    let padding = (maxTimeWidth - timeWidth) / 2
    let paddingV = 2.0

    if isOverlay {
      backgroundLayer.frame = CGRect(
        x: 0,
        y: 0,
        width: totalWidth,
        height: bounds.height
      )
    } else {
      backgroundLayer.frame = .zero
    }

    timeLayer.frame = CGRect(
      x: padding,
      y: (bounds.height - Self.timeHeight) / 2 - paddingV,
      width: timeWidth,
      height: Self.timeHeight
    )

    if hasSymbol {
      statusLayer.frame = CGRect(
        x: padding + timeWidth + 2,
        y: (bounds.height - symbolWidth + 2 + 1) / 2,
        width: symbolWidth - 2,
        height: symbolWidth - 2
      )
    }

    // Update tracking areas when layout changes
    updateTrackingAreas()
  }

  // MARK: - Content Updates

  public func updateMessage(_ fullMessage: FullMessage) {
    let oldStatus = self.fullMessage.message.status
    let oldDate = self.fullMessage.message.date
    let oldOut = self.fullMessage.message.out
    let oldIsOverlay = isOverlay

    self.fullMessage = fullMessage

    if fullMessage.message.date != oldDate || fullMessage.message.out != oldOut {
      updateTimeContent()
      updateTooltip()
    }

    if fullMessage.message.status != oldStatus {
      updateStatusContent()
    }

    if fullMessage.message.out != oldOut {
      updateColorStyles()
    }

    if oldIsOverlay != isOverlay {
      backgroundLayer.isHidden = !isOverlay
    }

    needsLayout = true
  }

  private func updateContent() {
    updateTimeContent()
    updateStatusContent()
    updateColorStyles()
  }

  private func updateTimeContent() {
    let string = isFailedMessage ? "Failed" : Self.formatter.string(from: fullMessage.message.date)
    let attributedString = NSAttributedString(
      string: string,
      attributes: [
        .font: Self.font,
        .foregroundColor: textColor,
      ]
    )
    timeLayer.string = attributedString
    let size = attributedString.size()
    timeWidth = size.width.rounded(.up)
  }

  private func updateStatusContent() {
    guard hasSymbol else { return }
    statusLayer.contents = createStatusImage()
  }

  private func updateColorStyles() {
    timeLayer.foregroundColor = textColor.cgColor
    statusLayer.contents = createStatusImage()
  }

  // MARK: - Image Generation

  // External Sizing

  static var formatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("jmm")
    formatter.locale = Locale.autoupdatingCurrent
    return formatter
  }()

  static var tooltipFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .full
    formatter.timeStyle = .medium
    formatter.locale = Locale.autoupdatingCurrent
    return formatter
  }()

  static var symbolWidth: CGFloat {
    12
  }

  static var font: NSFont = .systemFont(ofSize: 10, weight: .regular).withTraits(.italic)

  static var timeWidth: CGFloat = 0.0
  static var timeHeight: CGFloat = 0.0

  // Must be called once
  static func precalculateTimeWidth() {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("jmm")
    formatter.locale = Locale.autoupdatingCurrent

    MessageTimeAndState.formatter = formatter

    let timeFormatIs12Hour = (formatter.dateFormat ?? "").contains("a")
    let maxTimeString =
      if timeFormatIs12Hour {
        "12:59 PM"
      } else {
        "23:59"
      }

    let attributes: [NSAttributedString.Key: Any] = [
      .font: MessageTimeAndState.font,
    ]
    let size = NSAttributedString(
      string: maxTimeString,
      attributes: attributes
    ).size()
    let timeWidth = size.width.rounded(.up)
    let timeHeight = size.height.rounded(.up)

    MessageTimeAndState.timeWidth = ceil(timeWidth) + 4.0
    MessageTimeAndState.timeHeight = ceil(timeHeight) + 4.0
  }
}
