import AppKit
import InlineKit
import InlineUI
import Logger
import SwiftUI

class MessageTimeAndState: NSView {
  private var fullMessage: FullMessage
  private var currentState: MessageSendingStatus = .sent

  private var textColor: NSColor {
    fullMessage.message.out == true ? .white.withAlphaComponent(0.6) : .tertiaryLabelColor
  }

  private var hasSymbol: Bool {
    fullMessage.message.out == true
  }

  private var isFailedMessage: Bool {
    fullMessage.message.status == .failed
  }

  // MARK: - Layer Setup

  // Improved cache with scale awareness and memory management
  private static let imageCache = NSCache<NSString, CGImage>()

  // Key struct for proper cache identity
  fileprivate struct CacheKey: Hashable {
    let status: MessageSendingStatus
    let isFailed: Bool
    let scaleFactor: CGFloat
  }

  // MARK: - Layer Setup (Modified)

  private lazy var timeLayer: CATextLayer = createTextLayer()
  private lazy var statusLayer: CALayer = createStatusLayer()

  private func createTextLayer() -> CATextLayer {
    let layer = CATextLayer()
    layer.contentsScale = effectiveScaleFactor
    layer.font = Self.font
    layer.fontSize = 10
    layer.alignmentMode = .left
    layer.truncationMode = .end
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
      scaleFactor: scale
    )

    if let cached = Self.imageCache.object(forKey: cacheKey.key) {
      return cached
    }

    let symbolName = switch status {
      case .sent: "checkmark"
      case .sending: "clock"
      case .failed: "exclamationmark.triangle"
    }

    // Create a properly scaled configuration
    let config = NSImage.SymbolConfiguration(
      pointSize: 11 * scale, // Scale the point size
      weight: .semibold,
      scale: .small
    )
    .applying(.init(paletteColors: [color]))

    // Create the symbol image
    let symbolImage = NSImage(
      systemSymbolName: symbolName,
      accessibilityDescription: nil
    )?
      .withSymbolConfiguration(config)

    // Create a new image with the correct dimensions
    let size = CGSize(width: 12 * scale, height: 12 * scale)
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
      Self.imageCache.setObject(cgImage, forKey: cacheKey.key)
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
    layer?.addSublayer(timeLayer)
    layer?.addSublayer(statusLayer)
    statusLayer.isHidden = !hasSymbol
  }

  // MARK: - Layout

  override func layout() {
    super.layout()

    let timeWidth = Self.timeWidth
    timeLayer.frame = CGRect(
      x: 0,
      y: (bounds.height - Self.timeHeight) / 2,
      width: timeWidth,
      height: Self.timeHeight // timeLayer.preferredFrameSize().height
    )

    if hasSymbol {
      statusLayer.frame = CGRect(
        x: timeWidth,
        y: (bounds.height - 12) / 2,
        width: 12,
        height: 12
      )
    }
  }

  // MARK: - Content Updates

  public func updateMessage(_ fullMessage: FullMessage) {
    let oldStatus = self.fullMessage.message.status
    let oldDate = self.fullMessage.message.date
    let oldOut = self.fullMessage.message.out

    self.fullMessage = fullMessage

    if fullMessage.message.date != oldDate || fullMessage.message.out != oldOut {
      updateTimeContent()
    }

    if fullMessage.message.status != oldStatus {
      updateStatusContent()
    }

    if fullMessage.message.out != oldOut {
      updateColorStyles()
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
    timeLayer.string = NSAttributedString(
      string: string,
      attributes: [
        .font: Self.font,
        .foregroundColor: textColor,
      ]
    )
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

  static var symbolWidth: CGFloat {
    14
  }

  static var font: NSFont {
    NSFont.systemFont(ofSize: 10, weight: .regular).withTraits(.italic)
  }

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

    MessageTimeAndState.timeWidth = ceil(timeWidth)
    MessageTimeAndState.timeHeight = ceil(timeHeight)
  }
}

// CacheKey extension for NSCache compatibility
private extension MessageTimeAndState.CacheKey {
  var key: NSString {
    "\(status.rawValue)-\(isFailed)-\(scaleFactor)" as NSString
  }
}
