import AppKit
import MacTheme

final class TabStripCollectionViewItem: NSCollectionViewItem, TabStripItemHoverDelegate {
  var onClose: (() -> Void)?

  private enum Style {
    static let selectedTopRadius: CGFloat = 10
    static let selectedBottomCurveHeight: CGFloat = 10
    static let selectedBackgroundExtension: CGFloat = 10

    static let hoverCornerRadius: CGFloat = 8
    static let hoverInset: CGFloat = Theme.tabBarItemInset

    static let titleFontSize: CGFloat = 12
    static let iconSize: CGFloat = CollectionTabStripViewController.Layout.iconViewSize
    static let homeIconPointSize: CGFloat = 14
    static let iconLeadingPadding: CGFloat = 10
    static let iconTrailingPadding: CGFloat = 6
    static let titleFadeWidth: CGFloat = 10
    static let trailingInsetDefault: CGFloat = 15
    static let trailingInsetWithClose: CGFloat = 5
    static let closeOverlayWidth: CGFloat = 30
    static let extraFadePadding: CGFloat = 5
    static let homeIconTintColor: NSColor = .secondaryLabelColor
  }

  static func preferredWidth(for item: TabStripItem, iconSize: CGFloat) -> CGFloat {
    guard item.style != .home else { return 0 }

    let font = NSFont.systemFont(ofSize: Style.titleFontSize)
    let titleWidth = (item.title as NSString).size(withAttributes: [.font: font]).width

    return Style.iconLeadingPadding
      + iconSize
      + Style.iconTrailingPadding
      + ceil(titleWidth)
      + Style.trailingInsetDefault
  }

  private var isHovered = false
  private var isTabSelected = false
  private var isClosable = true
  private var isHomeTab = false

  private var iconWidthConstraint: NSLayoutConstraint!
  private var iconLeadingConstraint: NSLayoutConstraint!
  private var iconHeightConstraint: NSLayoutConstraint!
  private var titleTrailingConstraint: NSLayoutConstraint!
  private var iconCenterXForHome: NSLayoutConstraint!
  private var titleLeadingConstraint: NSLayoutConstraint!

  private let shadowView = NSView()
  private let backgroundView = TabStripSelectedBackgroundView()
  private let hoverBackgroundView = NSView()
  private let iconImageView = TabStripNonDraggableImageView()
  private let titleLabel = TabStripNonDraggableTextField(labelWithString: "")
  private let titleMaskLayer = CAGradientLayer()
  private let closeOverlay = TabStripCloseOverlayView()

  override init(nibName _: NSNib.Name?, bundle _: Bundle?) {
    super.init(nibName: nil, bundle: nil)
    setupViews()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setupViews()
  }

  private func setupViews() {
    view = TabStripItemView()
    if let tabView = view as? TabStripItemView {
      tabView.hoverDelegate = self
      tabView.onAppearanceChanged = { [weak self] in
        self?.updateAppearance(animated: false)
      }
      tabView.onCloseRequest = { [weak self] in
        self?.onClose?()
      }
    }
    view.wantsLayer = true

    shadowView.wantsLayer = true
    shadowView.translatesAutoresizingMaskIntoConstraints = false
    shadowView.alphaValue = 0
    view.addSubview(shadowView)

    backgroundView.wantsLayer = true
    backgroundView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(backgroundView)

    hoverBackgroundView.wantsLayer = true
    hoverBackgroundView.layer?.cornerRadius = Style.hoverCornerRadius
    hoverBackgroundView.translatesAutoresizingMaskIntoConstraints = false
    hoverBackgroundView.alphaValue = 0
    view.addSubview(hoverBackgroundView)

    iconImageView.wantsLayer = true
    iconImageView.imageScaling = .scaleProportionallyUpOrDown
    iconImageView.translatesAutoresizingMaskIntoConstraints = false
    iconImageView.setContentHuggingPriority(.required, for: .horizontal)
    iconImageView.setContentCompressionResistancePriority(.required, for: .horizontal)
    view.addSubview(iconImageView)

    titleLabel.font = NSFont.systemFont(ofSize: Style.titleFontSize)
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.maximumNumberOfLines = 1
    titleLabel.lineBreakMode = .byClipping
    titleLabel.isBezeled = false
    titleLabel.drawsBackground = false
    titleLabel.isEditable = false
    titleLabel.isSelectable = false
    titleLabel.wantsLayer = true
    view.addSubview(titleLabel)

    closeOverlay.translatesAutoresizingMaskIntoConstraints = false
    closeOverlay.alphaValue = 0
    view.addSubview(closeOverlay)
    closeOverlay.onClose = { [weak self] in
      self?.onClose?()
    }

    iconLeadingConstraint = iconImageView.leadingAnchor.constraint(
      equalTo: view.leadingAnchor,
      constant: Style.iconLeadingPadding
    )
    iconWidthConstraint = iconImageView.widthAnchor.constraint(equalToConstant: Style.iconSize)
    iconHeightConstraint = iconImageView.heightAnchor.constraint(equalToConstant: Style.iconSize)

    titleLeadingConstraint = titleLabel.leadingAnchor.constraint(
      equalTo: iconImageView.trailingAnchor,
      constant: Style.iconTrailingPadding
    )
    titleTrailingConstraint = titleLabel.trailingAnchor.constraint(
      equalTo: view.trailingAnchor,
      constant: -Style.trailingInsetDefault
    )
    iconCenterXForHome = iconImageView.centerXAnchor.constraint(equalTo: view.centerXAnchor)

    NSLayoutConstraint.activate([
      shadowView.topAnchor.constraint(equalTo: view.topAnchor),
      shadowView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: -Style.selectedBackgroundExtension),
      shadowView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: Style.selectedBackgroundExtension),
      shadowView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      backgroundView.topAnchor.constraint(equalTo: view.topAnchor),
      backgroundView.leadingAnchor.constraint(
        equalTo: view.leadingAnchor,
        constant: -Style.selectedBackgroundExtension
      ),
      backgroundView.trailingAnchor.constraint(
        equalTo: view.trailingAnchor,
        constant: Style.selectedBackgroundExtension
      ),
      backgroundView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      hoverBackgroundView.topAnchor.constraint(equalTo: view.topAnchor),
      hoverBackgroundView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      hoverBackgroundView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      hoverBackgroundView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -Style.hoverInset),

      iconLeadingConstraint,
      iconImageView.centerYAnchor.constraint(
        equalTo: view.centerYAnchor,
        constant: CollectionTabStripViewController.Layout.tabItemIconCenterYOffset
      ),
      iconWidthConstraint,
      iconHeightConstraint,
      iconCenterXForHome,

      titleLeadingConstraint,
      titleLabel.centerYAnchor.constraint(
        equalTo: view.centerYAnchor,
        constant: CollectionTabStripViewController.Layout.tabItemIconCenterYOffset
      ),
      titleTrailingConstraint,

      closeOverlay.topAnchor.constraint(equalTo: view.topAnchor),
      closeOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      closeOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      closeOverlay.widthAnchor.constraint(equalToConstant: Style.closeOverlayWidth),
    ])

    closeOverlay.setContentCompressionResistancePriority(.required, for: .horizontal)
    closeOverlay.setContentHuggingPriority(.required, for: .horizontal)
    titleLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
  }

  func configure(
    with item: TabStripItem,
    iconSize: CGFloat,
    scale: CGFloat = 1,
    selected: Bool,
    iconImage: NSImage? = nil
  ) {
    isTabSelected = selected
    isClosable = item.isClosable
    let paddingScale = max(0.4, scale)

    let isHome = item.style == .home
    isHomeTab = isHome

    if let tabView = view as? TabStripItemView {
      tabView.isClosable = item.isClosable && !isHome
    }

    titleLeadingConstraint.constant = isHome ? 0 : Style.iconTrailingPadding * paddingScale
    iconLeadingConstraint.constant = Style.iconLeadingPadding * paddingScale
    iconCenterXForHome.isActive = isHome
    iconLeadingConstraint.isActive = !isHome

    if isHome {
      iconWidthConstraint.constant = Style.homeIconPointSize
      iconHeightConstraint.constant = Style.homeIconPointSize
      iconImageView.layer?.cornerRadius = 0
      iconImageView.layer?.backgroundColor = NSColor.clear.cgColor
      iconImageView.imageScaling = .scaleNone

      let config = NSImage.SymbolConfiguration(
        pointSize: Style.homeIconPointSize,
        weight: .semibold,
        scale: .medium
      )
      let symbolName = item.systemIconName ?? "house"
      iconImageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
        .withSymbolConfiguration(config)
      iconImageView.contentTintColor = Style.homeIconTintColor
      titleLabel.stringValue = ""
      titleLabel.isHidden = true
      titleLeadingConstraint.isActive = false
      titleTrailingConstraint.isActive = false
      iconLeadingConstraint.isActive = false
      iconCenterXForHome.isActive = true
      closeOverlay.isHidden = true
      titleLabel.layer?.mask = nil
    } else {
      iconWidthConstraint.constant = iconSize
      iconHeightConstraint.constant = iconSize
      iconImageView.layer?.cornerRadius = iconSize / 3
      iconImageView.layer?.backgroundColor = iconImage == nil
        ? NSColor.systemGray.withAlphaComponent(0.3).cgColor
        : NSColor.clear.cgColor
      iconImageView.imageScaling = .scaleProportionallyUpOrDown
      iconImageView.image = iconImage
      iconImageView.contentTintColor = nil
      titleLabel.stringValue = item.title
      titleLabel.isHidden = false
      titleLeadingConstraint.isActive = true
      titleTrailingConstraint.isActive = true
      iconLeadingConstraint.isActive = true
      iconCenterXForHome.isActive = false
      titleTrailingConstraint.constant = -Style.trailingInsetDefault
      closeOverlay.isHidden = false
      titleLabel.layer?.mask = titleMaskLayer
    }

    updateAppearance(animated: false)
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    updateBackgroundShape()
    updateTitleMask()
  }

  private func updateBackgroundShape() {
    guard isTabSelected else { return }

    let bounds = backgroundView.bounds
    let topRadius = Style.selectedTopRadius
    let bottomCurveHeight = Style.selectedBottomCurveHeight
    let inset = Style.selectedBackgroundExtension

    let path = NSBezierPath()

    path.move(to: NSPoint(x: 0, y: 0))
    path.line(to: NSPoint(x: inset - bottomCurveHeight, y: 0))

    path.curve(
      to: NSPoint(x: inset, y: bottomCurveHeight),
      controlPoint1: NSPoint(x: inset - bottomCurveHeight, y: 0),
      controlPoint2: NSPoint(x: inset, y: 0)
    )

    path.line(to: NSPoint(x: inset, y: bounds.height - topRadius))

    path.appendArc(
      withCenter: NSPoint(x: inset + topRadius, y: bounds.height - topRadius),
      radius: topRadius,
      startAngle: 180,
      endAngle: 90,
      clockwise: true
    )

    path.line(to: NSPoint(x: bounds.width - inset - topRadius, y: bounds.height))

    path.appendArc(
      withCenter: NSPoint(x: bounds.width - inset - topRadius, y: bounds.height - topRadius),
      radius: topRadius,
      startAngle: 90,
      endAngle: 0,
      clockwise: true
    )

    path.line(to: NSPoint(x: bounds.width - inset, y: bottomCurveHeight))

    path.curve(
      to: NSPoint(x: bounds.width - inset + bottomCurveHeight, y: 0),
      controlPoint1: NSPoint(x: bounds.width - inset, y: 0),
      controlPoint2: NSPoint(x: bounds.width - inset + bottomCurveHeight, y: 0)
    )

    path.line(to: NSPoint(x: bounds.width, y: 0))
    path.line(to: NSPoint(x: 0, y: 0))
    path.close()

    let shapeLayer = CAShapeLayer()
    shapeLayer.path = path.cgPath
    backgroundView.layer?.mask = shapeLayer

    let shadowShapeLayer = CAShapeLayer()
    shadowShapeLayer.path = path.cgPath
    shadowShapeLayer.fillColor = NSColor.black.withAlphaComponent(0.1).cgColor
    shadowShapeLayer.frame = shadowView.bounds

    if let blurFilter = CIFilter(name: "CIGaussianBlur") {
      blurFilter.setValue(3.0, forKey: kCIInputRadiusKey)
      shadowShapeLayer.filters = [blurFilter]
    }

    shadowView.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
    shadowView.layer?.addSublayer(shadowShapeLayer)

    let maskPath = NSBezierPath(rect: NSRect(
      x: 0,
      y: 0,
      width: bounds.width,
      height: bounds.height + 10
    ))
    let maskLayer = CAShapeLayer()
    maskLayer.path = maskPath.cgPath
    shadowView.layer?.mask = maskLayer
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    isHovered = false
    isTabSelected = false
    isClosable = true
    if let tabView = view as? TabStripItemView {
      tabView.isClosable = true
    }
    titleLabel.layer?.mask = titleMaskLayer
    titleLeadingConstraint.isActive = true
    titleTrailingConstraint.isActive = true
    iconLeadingConstraint.isActive = true
    iconCenterXForHome.isActive = false
    updateAppearance(animated: false)
  }

  func tabHoverDidChange(isHovered: Bool) {
    self.isHovered = isHovered
    updateAppearance()
  }

  private func updateAppearance(animated _: Bool = false) {
    updateBackgroundShape()

    let isDarkMode = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let activeBackgroundColor = Theme.windowContentBackgroundColor
      .resolvedColor(with: view.effectiveAppearance)

    let shadowAlpha: CGFloat
    let backgroundAlpha: CGFloat
    let hoverAlpha: CGFloat

    if isTabSelected {
      shadowAlpha = 1
      backgroundAlpha = 1
      hoverAlpha = 0
    } else if isHovered {
      shadowAlpha = 0
      backgroundAlpha = 0
      hoverAlpha = 1
      hoverBackgroundView.layer?.backgroundColor = NSColor.systemGray.withAlphaComponent(0.15).cgColor
    } else {
      shadowAlpha = 0
      backgroundAlpha = 0
      hoverAlpha = 0
    }

    shadowView.alphaValue = shadowAlpha
    backgroundView.alphaValue = backgroundAlpha
    hoverBackgroundView.alphaValue = hoverAlpha

    let shouldShowClose = !isHomeTab && isTabSelected && isHovered && isClosable
    closeOverlay.setBaseColor(activeBackgroundColor, isDarkMode: isDarkMode)
    closeOverlay.setVisible(shouldShowClose)

    guard !isHomeTab else { return }

    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0
      context.allowsImplicitAnimation = false

      let trailingConstant: CGFloat = if shouldShowClose {
        -(Style.closeOverlayWidth + Style.trailingInsetWithClose)
      } else {
        -Style.trailingInsetDefault
      }
      titleTrailingConstraint.constant = trailingConstant

      view.layoutSubtreeIfNeeded()
      updateTitleMask()
    }
  }

  private func updateTitleMask() {
    guard !titleLabel.isHidden, let layer = titleLabel.layer else { return }

    let bounds = titleLabel.bounds
    guard bounds.width > 0, bounds.height > 0 else { return }

    let extraPadding = (titleTrailingConstraint.constant == -(Style.closeOverlayWidth + Style.trailingInsetWithClose))
      ? 0
      : Style.extraFadePadding
    let fadeWidth = min(Style.titleFadeWidth + extraPadding, bounds.width)

    let textSize = titleLabel.attributedStringValue.size()
    let needsFade = textSize.width > bounds.width - fadeWidth

    if !needsFade {
      let fullMask = CALayer()
      fullMask.frame = bounds
      fullMask.backgroundColor = NSColor.white.cgColor
      layer.mask = fullMask
      return
    }

    var maskFrame = bounds
    maskFrame.size.width += extraPadding
    titleMaskLayer.frame = maskFrame
    titleMaskLayer.startPoint = CGPoint(x: 0, y: 0.5)
    titleMaskLayer.endPoint = CGPoint(x: 1, y: 0.5)
    let fadeStart = max(0, (maskFrame.width - fadeWidth) / maskFrame.width)
    titleMaskLayer.locations = [0, NSNumber(value: Double(fadeStart)), 1]
    titleMaskLayer.colors = [
      NSColor.white.cgColor,
      NSColor.white.cgColor,
      NSColor.clear.cgColor,
    ]

    layer.mask = titleMaskLayer
  }
}

private final class TabStripSelectedBackgroundView: NSView {
  init() {
    super.init(frame: .zero)
    wantsLayer = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func updateLayer() {
    super.updateLayer()
    layer?.backgroundColor = Theme.windowContentBackgroundColor
      .resolvedColor(with: effectiveAppearance)
      .cgColor
  }
}

private extension NSColor {
  /// Resolve dynamic AppKit colors against a specific appearance before converting to CGColor.
  func resolvedColor(with appearance: NSAppearance) -> NSColor {
    var resolved: NSColor = self
    appearance.performAsCurrentDrawingAppearance {
      resolved = self.usingType(.componentBased) ?? self.usingColorSpace(.deviceRGB) ?? self
    }
    return resolved
  }
}
