import AppKit
import InlineKit
import InlineUI
import Logger
import SwiftUI

class MessageTimeAndState: NSView {
  enum ContentAlignment: Equatable {
    case left
    case center
    case right

    var layerAlignment: CATextLayerAlignmentMode {
      switch self {
      case .left:
        return .left
      case .center:
        return .center
      case .right:
        return .right
      }
    }
  }

  private var fullMessage: FullMessage
  /// "Sent via Codex · " before the time on the last message of an agent's run.
  private var viaPrefix: String?
  /// One generic sentence about the agent, shown in the tooltip.
  private var viaDetail: String?
  private var viaPrefixWidth: CGFloat = 0
  private var currentState: MessageSendingStatus = .sent
  /// Registers the date tooltip. Each registered tooltip is a rect AppKit keeps in sync while
  /// rows scroll, so minimal rows that hide their time turn it off.
  var showsToolTip = true {
    didSet {
      guard showsToolTip != oldValue else { return }
      updateTooltip()
    }
  }

  private var isOverlay: Bool
  private var usesOutgoingBubbleStyle: Bool
  private var contentAlignment: ContentAlignment

  private var textColor: NSColor {
    if isOverlay {
      .white.withAlphaComponent(0.8)
    } else if usesOutgoingBubbleStyle {
      .white.withAlphaComponent(0.7)
    } else {
      .tertiaryLabelColor
    }
  }

  /// Concrete color for this view's appearance. CATextLayer skips redraws for an equal attributed
  /// string (a dynamic color compares equal across appearances) and resolves dynamic colors at draw
  /// time against the wrong appearance, so never hand it `textColor` directly.
  private var resolvedTextColor: NSColor {
    textColor.resolvedColor(with: effectiveAppearance)
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
    let usesOutgoingBubbleStyle: Bool
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
    layer.alignmentMode = contentAlignment.layerAlignment
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
  /// The appearance the text color and status image were resolved for.
  private var contentAppearance: NSAppearance.Name?

  // Dynamic scale factor handling
  private var effectiveScaleFactor: CGFloat {
    window?.backingScaleFactor ?? window?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1.0
  }

  // MARK: - Image Generation (Improved)

  private func createStatusImage() -> CGImage? {
    let status = fullMessage.message.status ?? .sent
    let color = resolvedTextColor
    let scale = effectiveScaleFactor
    let cacheKey = CacheKey(
      status: status,
      isFailed: isFailedMessage,
      scaleFactor: scale,
      isOutgoing: fullMessage.message.out ?? false,
      isOverlay: isOverlay,
      usesOutgoingBubbleStyle: usesOutgoingBubbleStyle,
      isDarkMode: effectiveAppearance.isDarkMode
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
    // Re-parenting a row reports a change without one.
    guard effectiveScaleFactor != appliedScaleFactor else { return }
    updateScaleFactors()
  }

  /// The scale the layers were last set for by `updateScaleFactors`.
  private var appliedScaleFactor: CGFloat = 0

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    // Re-parenting a row reports an appearance change without one; the text, its width and
    // the status image only depend on which appearance it is.
    guard effectiveAppearance.name != contentAppearance else { return }
    contentAppearance = effectiveAppearance.name
    // Switch in sync with the bubble background instead of cross-fading.
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    updateTimeContent()
    updateColorStyles()
    CATransaction.commit()
    needsLayout = true
  }

  private func updateScaleFactors() {
    let scale = effectiveScaleFactor
    appliedScaleFactor = scale
    timeLayer.contentsScale = scale
    statusLayer.contentsScale = scale
    statusLayer.rasterizationScale = scale
    statusLayer.contents = createStatusImage()
  }

  // MARK: - Initialization

  init(
    fullMessage: FullMessage,
    overlay: Bool,
    usesOutgoingBubbleStyle: Bool = false,
    contentAlignment: ContentAlignment = .center,
    via: MessageViaPresentation? = nil,
    showsToolTip: Bool = true
  ) {
    self.fullMessage = fullMessage
    self.showsToolTip = showsToolTip
    viaPrefix = via.map { Self.viaPrefix(for: $0) }
    viaDetail = via?.detail(senderName: fullMessage.senderInfo?.user.shortDisplayName)
    viaPrefixWidth = Self.viaPrefixWidth(viaPrefix)
    isOverlay = overlay
    self.usesOutgoingBubbleStyle = usesOutgoingBubbleStyle
    self.contentAlignment = contentAlignment
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
  }

  /// The tooltip's rect, registered once while it shows; AppKit asks for the text when the pointer rests on it
  /// (`view(_:stringForToolTip:point:userData:)`), so rows that scroll past format no dates and register nothing.
  private var toolTipTag: NSView.ToolTipTag?

  private func updateTooltip() {
    guard showsToolTip, !bounds.isEmpty else {
      if let toolTipTag {
        removeToolTip(toolTipTag)
        self.toolTipTag = nil
      }
      return
    }
    guard toolTipTag == nil else { return }
    toolTipTag = addToolTip(bounds, owner: self, userData: nil)
  }

  fileprivate var tooltipText: String {
    let date = Self.tooltipFormatter.string(from: fullMessage.message.date)
    return viaDetail.map { "\($0)\n\(date)" } ?? date
  }

  override func setFrameSize(_ newSize: NSSize) {
    let resized = newSize != frame.size
    super.setFrameSize(newSize)
    guard resized else { return }
    if let toolTipTag {
      removeToolTip(toolTipTag)
      self.toolTipTag = nil
    }
    updateTooltip()
  }

  // MARK: - Layout

  override func layout() {
    super.layout()

    let maxTimeWidth = Self.timeWidth + viaPrefixWidth
    let symbolWidth = Self.symbolWidth
    let totalWidth = maxTimeWidth + (hasSymbol ? symbolWidth : 0.0)
    let timeX: CGFloat = switch contentAlignment {
    case .left:
      0
    case .center:
      (maxTimeWidth - timeWidth) / 2
    case .right:
      maxTimeWidth - timeWidth
    }
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
      x: max(0, timeX),
      y: (bounds.height - Self.timeHeight) / 2 - paddingV,
      width: timeWidth,
      height: Self.timeHeight
    )

    if hasSymbol {
      statusLayer.frame = CGRect(
        x: max(0, timeX) + timeWidth + 2,
        y: (bounds.height - symbolWidth + 2 + 1) / 2,
        width: symbolWidth - 2,
        height: symbolWidth - 2
      )
    }
  }

  // MARK: - Content Updates

  func updateMessage(
    _ fullMessage: FullMessage,
    overlay: Bool,
    usesOutgoingBubbleStyle: Bool = false,
    contentAlignment: ContentAlignment? = nil,
    via: MessageViaPresentation? = nil
  ) {
    let nextViaPrefix = via.map { Self.viaPrefix(for: $0) }
    let viaChanged = nextViaPrefix != viaPrefix
    if viaChanged {
      viaPrefix = nextViaPrefix
      viaDetail = via?.detail(senderName: fullMessage.senderInfo?.user.shortDisplayName)
      viaPrefixWidth = Self.viaPrefixWidth(nextViaPrefix)
    }

    let oldStatus = self.fullMessage.message.status
    let oldDate = self.fullMessage.message.date
    let oldOut = self.fullMessage.message.out
    let oldIsOverlay = isOverlay
    let oldUsesOutgoingBubbleStyle = self.usesOutgoingBubbleStyle
    let oldContentAlignment = self.contentAlignment

    self.fullMessage = fullMessage
    isOverlay = overlay
    self.usesOutgoingBubbleStyle = usesOutgoingBubbleStyle
    if let contentAlignment {
      self.contentAlignment = contentAlignment
    }

    if fullMessage.message.date != oldDate || fullMessage.message.out != oldOut {
      updateTimeContent()
      updateTooltip()
    }

    if fullMessage.message.status != oldStatus {
      if (oldStatus == .failed) != isFailedMessage {
        updateTimeContent()
      }
      updateStatusContent()
    }

    if fullMessage.message.out != oldOut {
      // A reused row can move between outgoing and incoming messages; only outgoing ones show status.
      statusLayer.isHidden = !hasSymbol
      updateColorStyles()
    }

    if oldUsesOutgoingBubbleStyle != usesOutgoingBubbleStyle {
      updateTimeContent()
      updateColorStyles()
    }

    if oldIsOverlay != isOverlay {
      updateTimeContent()
      updateColorStyles()
      CATransaction.setDisableActions(true)
      backgroundLayer.isHidden = !isOverlay
    }

    if oldContentAlignment != self.contentAlignment {
      timeLayer.alignmentMode = self.contentAlignment.layerAlignment
    }

    if viaChanged {
      updateTimeContent()
      updateTooltip()
    }

    needsLayout = true
  }

  private func updateContent() {
    contentAppearance = effectiveAppearance.name
    updateTimeContent()
    updateStatusContent()
    updateColorStyles()
  }

  private func updateTimeContent() {
    let string: String
    if isFailedMessage {
      string = "Failed"
      timeWidth = Self.width(of: string)
    } else if let viaPrefix {
      string = viaPrefix + Self.timeText(for: fullMessage.message.date).string
      timeWidth = Self.width(of: string)
    } else {
      let text = Self.timeText(for: fullMessage.message.date)
      string = text.string
      timeWidth = text.width
    }
    let attributedString = NSAttributedString(
      string: string,
      attributes: [
        .font: Self.font,
        .foregroundColor: resolvedTextColor,
      ]
    )
    timeLayer.string = attributedString
  }

  /// Text widths by string: the font is fixed, and rows show the same few hundred times over and over.
  private static var widths: [String: CGFloat] = [:]

  private static func width(of string: String) -> CGFloat {
    if let width = widths[string] { return width }
    if widths.count > 4096 { widths.removeAll(keepingCapacity: true) }
    let width = measuredWidth(of: string, font: font)
    widths[string] = width
    return width
  }

  /// The line's typographic width equals `NSAttributedString.size()` here (checked for every minute in ten locales,
  /// "Sent via" prefixes included) at about half the cost. Safe off the main thread.
  private nonisolated static func measuredWidth(of string: String, font: NSFont) -> CGFloat {
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [.font: font]))
    return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)).rounded(.up)
  }

  private static var widthPrefillGeneration = 0

  /// The formatter's strings are bridged (with U+202F before AM/PM), and hashing a bridged string runs Unicode
  /// normalization each time: a dictionary keyed by them cost ~10 ms to fill. Native UTF-8 hashes fast.
  private nonisolated static func nativeString(_ string: String) -> String {
    var native = string
    native.makeContiguousUTF8()
    return native
  }

  /// Measures every minute of a day in the current format off the main thread: messages are minutes apart, so most
  /// rows show a time not seen yet, and each one cost a Core Text line in configure. Widths measured meanwhile win.
  private static func prefillWidths() {
    widthPrefillGeneration += 1
    let generation = widthPrefillGeneration
    guard let formatter = formatter.copy() as? DateFormatter else { return }
    let font = font
    DispatchQueue.global(qos: .utility).async {
      var table: [String: CGFloat] = [:]
      table.reserveCapacity(24 * 60)
      let start = Calendar.current.startOfDay(for: Date())
      for minute in 0 ..< 24 * 60 {
        let string = nativeString(formatter.string(from: start.addingTimeInterval(TimeInterval(minute * 60))))
        if table[string] == nil { table[string] = measuredWidth(of: string, font: font) }
      }
      let filled = table
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard generation == widthPrefillGeneration else { return }
          if widths.isEmpty {
            widths = filled
          } else {
            widths.merge(filled) { measured, _ in measured }
          }
        }
      }
    }
  }

  private struct TimeText {
    let string: String
    let width: CGFloat
  }

  /// Formatted times and their widths by absolute minute (the format shows hours and minutes only): formatting
  /// and measuring were most of a reconfigure. Cleared with the format and when the time zone or locale changes.
  private static var timeTexts: [Int64: TimeText] = [:]

  private static let timeTextResetObservers: [NSObjectProtocol] = [
    Notification.Name.NSSystemTimeZoneDidChange,
    NSLocale.currentLocaleDidChangeNotification,
  ].map { name in
    NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { MessageTimeAndState.timeTexts.removeAll() }
    }
  }

  private static func timeText(for date: Date) -> TimeText {
    _ = timeTextResetObservers
    let minute = Int64((date.timeIntervalSinceReferenceDate / 60).rounded(.down))
    if let cached = timeTexts[minute] { return cached }
    if timeTexts.count > 4096 { timeTexts.removeAll(keepingCapacity: true) }
    let string = nativeString(formatter.string(from: date))
    let text = TimeText(string: string, width: width(of: string))
    timeTexts[minute] = text
    return text
  }

  private func updateStatusContent() {
    guard hasSymbol else { return }
    statusLayer.contents = createStatusImage()
  }

  private func updateColorStyles() {
    timeLayer.foregroundColor = resolvedTextColor.cgColor
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
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    formatter.locale = Locale.autoupdatingCurrent
    return formatter
  }()

  static var symbolWidth: CGFloat {
    12
  }

  static var font: NSFont = .systemFont(ofSize: 10, weight: .regular) // .withTraits(.italic)

  static var timeWidth: CGFloat = 0.0
  static var timeHeight: CGFloat = 0.0

  static func viaPrefix(for via: MessageViaPresentation) -> String {
    "\(via.label) · "
  }

  /// Extra width the time slot needs for a "Sent via …" prefix.
  static func viaPrefixWidth(_ prefix: String?) -> CGFloat {
    guard let prefix, !prefix.isEmpty else { return 0 }
    return NSAttributedString(string: prefix, attributes: [.font: font]).size().width.rounded(.up)
  }

  // Must be called once
  static func precalculateTimeWidth() {
    widths.removeAll()
    timeTexts.removeAll()
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
    prefillWidths()
  }
}

extension MessageTimeAndState: NSViewToolTipOwner {
  func view(_: NSView, stringForToolTip _: NSView.ToolTipTag, point _: NSPoint, userData _: UnsafeMutableRawPointer?) -> String {
    tooltipText
  }
}
