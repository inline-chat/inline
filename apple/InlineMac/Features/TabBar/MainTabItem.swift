import AppKit

protocol TabBarItemHoverDelegate: AnyObject {
  func tabHoverDidChange(isHovered: Bool)
}

class TabCollectionViewItem: NSCollectionViewItem, TabBarItemHoverDelegate {
  var onClose: (() -> Void)?

  // MARK: - Style Constants

  private enum Style {
    // Selected tab background (extends beyond bounds with melting effect)
    static let selectedTopRadius: CGFloat = 10
    static let selectedBottomCurveHeight: CGFloat = 10
    static let selectedBackgroundExtension: CGFloat = 10

    // Hover background (stays within bounds)
    static let hoverCornerRadius: CGFloat = 8
    static let hoverInset: CGFloat = Theme.tabBarItemInset

    // Animation
    static let animationDuration: TimeInterval = 0.15

    // Typography & sizing
    static let titleFontSize: CGFloat = 12
    static let iconSize: CGFloat = MainTabBar.Layout.iconViewSize
    static let homeIconPointSize: CGFloat = 14
    static let iconCornerRadius: CGFloat = 6
    static let iconLeadingPadding: CGFloat = 10
    static let iconTrailingPadding: CGFloat = 6
    static let titleFadeWidth: CGFloat = 10
    static let trailingInsetDefault: CGFloat = 15
    static let trailingInsetWithClose: CGFloat = 5
    static let closeOverlayWidth: CGFloat = 25
    static let extraFadePadding: CGFloat = 5
    static let homeIconTintColor: NSColor = .secondaryLabelColor
  }

  static func preferredWidth(for tab: TabModel, iconSize: CGFloat) -> CGFloat {
    // Home tab is handled separately (fixed width).
    guard tab.icon != "house" else { return 0 }

    let font = NSFont.systemFont(ofSize: Style.titleFontSize)
    let titleWidth = (tab.title as NSString).size(withAttributes: [.font: font]).width
    // Don't reserve extra room for the close overlay; it floats over the tab.
    let trailing = Style.trailingInsetDefault

    return Style.iconLeadingPadding
      + iconSize
      + Style.iconTrailingPadding
      + ceil(titleWidth)
      + trailing
  }

  // MARK: - State

  private var isHovered = false
  private var isTabSelected = false
  private var isClosable = true
  private var isHomeTab = false

  // MARK: - Views

  private var iconWidthConstraint: NSLayoutConstraint!
  private var iconLeadingConstraint: NSLayoutConstraint!
  private var iconHeightConstraint: NSLayoutConstraint!
  private var titleTrailingConstraint: NSLayoutConstraint!
  private var iconCenterXForHome: NSLayoutConstraint!
  private var iconCenterYConstraint: NSLayoutConstraint!
  private var titleCenterYConstraint: NSLayoutConstraint!

  private let shadowView = NSView()
  private let backgroundView = TabSelectedBackgroundView()
  private let hoverBackgroundView = NSView()
  private let iconImageView = NonDraggableImageView()
  private let titleLabel = NonDraggableTextField(labelWithString: "")
  private let titleMaskLayer = CAGradientLayer()
  private let closeOverlay = TabCloseOverlayView()

  // Constraints we toggle for home vs regular tabs
  private var titleLeadingConstraint: NSLayoutConstraint!

  override init(nibName _: NSNib.Name?, bundle _: Bundle?) {
    super.init(nibName: nil, bundle: nil)
    setupViews()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setupViews()
  }

  private func setupViews() {
    view = TabBarItemView()
    if let tabView = view as? TabBarItemView {
      tabView.hoverDelegate = self
      tabView.onAppearanceChanged = { [weak self] in
        self?.updateAppearance(animated: false)
      }
      tabView.onCloseRequest = { [weak self] in
        self?.onClose?()
      }
    }
    view.wantsLayer = true

    // Shadow/glow for selected tabs (blurred duplicate of background shape)
    shadowView.wantsLayer = true
    shadowView.translatesAutoresizingMaskIntoConstraints = false
    shadowView.alphaValue = 0
    view.addSubview(shadowView)

    // Background for selected tabs (extends beyond bounds for melting effect)
    backgroundView.wantsLayer = true
    backgroundView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(backgroundView)

    // Background for hovered/unselected tabs (stays within bounds with inset)
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
    // Prevent drags starting on the icon from moving the window when inside the titlebar area.
    iconImageView.postsFrameChangedNotifications = false
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
    iconCenterYConstraint = iconImageView.centerYAnchor.constraint(
      equalTo: view.centerYAnchor,
      constant: MainTabBar.Layout.tabItemIconCenterYOffset
    )

    titleLeadingConstraint = titleLabel.leadingAnchor.constraint(
      equalTo: iconImageView.trailingAnchor,
      constant: Style.iconTrailingPadding
    )
    titleTrailingConstraint = titleLabel.trailingAnchor.constraint(
      equalTo: view.trailingAnchor,
      constant: -Style.trailingInsetDefault
    )
    titleCenterYConstraint = titleLabel.centerYAnchor.constraint(
      equalTo: view.centerYAnchor,
      constant: MainTabBar.Layout.tabItemIconCenterYOffset
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

      hoverBackgroundView.topAnchor.constraint(equalTo: view.topAnchor, constant: 0),
      hoverBackgroundView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 0),
      hoverBackgroundView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: 0),
      hoverBackgroundView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -Style.hoverInset),

      iconLeadingConstraint!,
      iconCenterYConstraint!,
      iconWidthConstraint,
      iconHeightConstraint,
      iconCenterXForHome,

      titleLeadingConstraint!,
      titleCenterYConstraint!,
      titleTrailingConstraint!,

      closeOverlay.topAnchor.constraint(equalTo: view.topAnchor),
      closeOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      closeOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      closeOverlay.widthAnchor.constraint(equalToConstant: Style.closeOverlayWidth),
    ])
    // Keep the close overlay from shrinking when space gets tight.
    closeOverlay.setContentCompressionResistancePriority(.required, for: .horizontal)
    closeOverlay.setContentHuggingPriority(.required, for: .horizontal)
    titleLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
  }

  func configure(
    with tab: TabModel,
    iconSize: CGFloat,
    scale: CGFloat = 1,
    selected: Bool,
    closable: Bool,
    iconImage: NSImage? = nil
  ) {
    isTabSelected = selected
    isClosable = closable
    let paddingScale = max(0.4, scale)

    let isHome = tab.icon == "house"
    isHomeTab = isHome

    // Update context menu availability
    if let tabView = view as? TabBarItemView {
      tabView.isClosable = closable && !isHome
    }

    // Toggle layout constraints for home vs regular tabs
    titleLeadingConstraint.constant = isHome ? 0 : Style.iconTrailingPadding * paddingScale
    iconLeadingConstraint.constant = Style.iconLeadingPadding * paddingScale
    iconCenterXForHome.isActive = isHome
    iconLeadingConstraint.isActive = !isHome

    if isHome {
      // Home tab: uses system house symbol, no title or close button
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
      iconImageView.image = NSImage(systemSymbolName: tab.icon, accessibilityDescription: nil)?
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
      // Other tabs: square badge with soft corners
      iconWidthConstraint.constant = iconSize
      iconHeightConstraint.constant = iconSize
      iconImageView.layer?.cornerRadius = iconSize / 3
      iconImageView.layer?.backgroundColor = iconImage == nil
        ? NSColor.systemGray.withAlphaComponent(0.3).cgColor
        : NSColor.clear.cgColor
      iconImageView.imageScaling = .scaleProportionallyUpOrDown
      iconImageView.image = iconImage
      titleLabel.stringValue = tab.title
      titleLabel.isHidden = false
      titleLeadingConstraint.isActive = true
      titleTrailingConstraint.isActive = true
      iconLeadingConstraint.isActive = true
      iconCenterXForHome.isActive = false
      titleTrailingConstraint.constant = -Style.trailingInsetDefault
      closeOverlay.isHidden = false
      titleLabel.layer?.mask = titleMaskLayer
    }

    titleLabel.stringValue = isHome ? "" : tab.title
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

    // Bottom left concave curve (melting effect)
    path.curve(
      to: NSPoint(x: inset, y: bottomCurveHeight),
      controlPoint1: NSPoint(x: inset - bottomCurveHeight, y: 0),
      controlPoint2: NSPoint(x: inset, y: 0)
    )

    path.line(to: NSPoint(x: inset, y: bounds.height - topRadius))

    // Top left rounded corner
    path.appendArc(
      withCenter: NSPoint(x: inset + topRadius, y: bounds.height - topRadius),
      radius: topRadius,
      startAngle: 180,
      endAngle: 90,
      clockwise: true
    )

    path.line(to: NSPoint(x: bounds.width - inset - topRadius, y: bounds.height))

    // Top right rounded corner
    path.appendArc(
      withCenter: NSPoint(x: bounds.width - inset - topRadius, y: bounds.height - topRadius),
      radius: topRadius,
      startAngle: 90,
      endAngle: 0,
      clockwise: true
    )

    path.line(to: NSPoint(x: bounds.width - inset, y: bottomCurveHeight))

    // Bottom right concave curve (melting effect)
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

    // Create shadow/glow layer with same shape
    let shadowShapeLayer = CAShapeLayer()
    shadowShapeLayer.path = path.cgPath
    shadowShapeLayer.fillColor = NSColor.black.withAlphaComponent(0.1).cgColor
    shadowShapeLayer.frame = shadowView.bounds

    // Apply blur filter to create glow effect
    let blurFilter = CIFilter(name: "CIGaussianBlur")
    blurFilter?.setValue(3.0, forKey: kCIInputRadiusKey)
    shadowShapeLayer.filters = [blurFilter].compactMap(\.self)

    shadowView.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
    shadowView.layer?.addSublayer(shadowShapeLayer)

    // Mask the shadow to hide the bottom part that would overlap content
    let maskPath = NSBezierPath(rect: NSRect(
      x: 0,
      y: 0, // bottomCurveHeight,
      width: bounds.width,
      height: bounds.height + 10 // - bottomCurveHeight
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
    if let tabView = view as? TabBarItemView {
      tabView.isClosable = true
    }
    titleLabel.layer?.mask = titleMaskLayer
    titleLeadingConstraint.isActive = true
    titleTrailingConstraint.isActive = true
    iconLeadingConstraint.isActive = true
    iconCenterXForHome.isActive = false
    updateAppearance(animated: false)
  }

  // MARK: - TabBarItemHoverDelegate

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
      // backgroundView.layer?.backgroundColor = activeBackgroundColor.cgColor
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

      // Apply layout updates before masking so bounds are accurate for hover/close states.
      view.layoutSubtreeIfNeeded()
      updateTitleMask()
    }
  }

  private func updateTitleMask() {
    guard !titleLabel.isHidden, let layer = titleLabel.layer else { return }

    let bounds = titleLabel.bounds
    guard bounds.width > 0, bounds.height > 0 else { return }

    let extraPadding = (titleTrailingConstraint.constant == -(Style.closeOverlayWidth + Style.trailingInsetWithClose)) ?
      0 : Style.extraFadePadding
    let fadeWidth = min(Style.titleFadeWidth + extraPadding, bounds.width)

    // Measure text width
    let textSize = titleLabel.attributedStringValue.size()
    let needsFade = textSize.width > bounds.width - fadeWidth

    if !needsFade {
      // Fully opaque mask
      let fullMask = CALayer()
      fullMask.frame = bounds
      fullMask.backgroundColor = NSColor.white.cgColor
      layer.mask = fullMask
      return
    }

    // Extend the mask slightly past the trailing edge so clipped glyph tails stay hidden.
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

private class TabSelectedBackgroundView: NSView {
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
