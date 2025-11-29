import AppKit

private final class TabBarItemView: NSView {
  override var mouseDownCanMoveWindow: Bool { false }
}

private final class NonDraggableTextField: NSTextField {
  override var mouseDownCanMoveWindow: Bool { false }
}

private final class NonDraggableButton: NSButton {
  override var mouseDownCanMoveWindow: Bool { false }
}

private final class NonDraggableImageView: NSImageView {
  override var mouseDownCanMoveWindow: Bool { false }
}

class TabCollectionViewItem: NSCollectionViewItem {
  var onClose: (() -> Void)?

  // MARK: - Style Constants

  private enum Style {
    // Selected tab background (extends beyond bounds with melting effect)
    static let selectedTopRadius: CGFloat = 14
    static let selectedBottomCurveHeight: CGFloat = 12
    static let selectedBackgroundExtension: CGFloat = 10

    // Hover background (stays within bounds)
    static let hoverCornerRadius: CGFloat = 8
    static let hoverInset: CGFloat = Theme.tabBarItemInset

    // Animation
    static let animationDuration: TimeInterval = 0.15

    // Typography & sizing
    static let titleFontSize: CGFloat = 13
    static let iconSize: CGFloat = 22
    static let homeIconPointSize: CGFloat = 15
    static let iconCornerRadius: CGFloat = 6
    static let iconLeadingPadding: CGFloat = 10
    static let iconTrailingPadding: CGFloat = 8
  }

  // MARK: - State

  private var isHovered = false
  private var isTabSelected = false
  private var isClosable = true

  // MARK: - Views

  private var iconWidthConstraint: NSLayoutConstraint!
  private var iconHeightConstraint: NSLayoutConstraint!

  private let shadowView = NSView()
  private let backgroundView = NSView()
  private let hoverBackgroundView = NSView()
  private let iconImageView = NonDraggableImageView()
  private let titleLabel = NonDraggableTextField(labelWithString: "")
  private let closeButton = NonDraggableButton()

  // Constraints we toggle for home vs regular tabs
  private var titleLeadingConstraint: NSLayoutConstraint!
  private var closeLeadingConstraint: NSLayoutConstraint!
  private var closeTrailingConstraint: NSLayoutConstraint!
  private var closeWidthConstraint: NSLayoutConstraint!
  private var iconTrailingConstraintForHome: NSLayoutConstraint!
  private var mainTrackingArea: NSTrackingArea?
  private var closeTrackingArea: NSTrackingArea?
  private var isCloseHovered = false

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
    // Prevent drags starting on the icon from moving the window when inside the titlebar area.
    iconImageView.postsFrameChangedNotifications = false
    view.addSubview(iconImageView)

    titleLabel.font = NSFont.systemFont(ofSize: Style.titleFontSize)
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.maximumNumberOfLines = 1
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.isBezeled = false
    titleLabel.drawsBackground = false
    titleLabel.isEditable = false
    titleLabel.isSelectable = false
    view.addSubview(titleLabel)

    closeButton.isBordered = false
    closeButton.bezelStyle = .regularSquare
    closeButton.imageScaling = .scaleProportionallyDown
    closeButton.contentTintColor = .secondaryLabelColor
    closeButton.translatesAutoresizingMaskIntoConstraints = false
    closeButton.setButtonType(.momentaryChange)
    closeButton.target = self
    closeButton.action = #selector(closeButtonTapped)
    closeButton.alphaValue = 0
    let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .medium)
    closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?
      .withSymbolConfiguration(config)
    view.addSubview(closeButton)

    iconWidthConstraint = iconImageView.widthAnchor.constraint(equalToConstant: Style.iconSize)
    iconHeightConstraint = iconImageView.heightAnchor.constraint(equalToConstant: Style.iconSize)

    titleLeadingConstraint = titleLabel.leadingAnchor.constraint(
      equalTo: iconImageView.trailingAnchor,
      constant: Style.iconTrailingPadding
    )
    closeLeadingConstraint = closeButton.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 6)
    closeTrailingConstraint = closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6)
    closeWidthConstraint = closeButton.widthAnchor.constraint(equalToConstant: 14)
    iconTrailingConstraintForHome = iconImageView.trailingAnchor.constraint(
      equalTo: view.trailingAnchor,
      constant: -Style.iconLeadingPadding
    )

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

      iconImageView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Style.iconLeadingPadding),
      iconImageView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      iconWidthConstraint,
      iconHeightConstraint,

      titleLeadingConstraint!,
      titleLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),

      closeLeadingConstraint!,
      closeTrailingConstraint!,
      closeButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      closeWidthConstraint!,
      closeButton.heightAnchor.constraint(equalToConstant: 14),
    ])

    refreshTrackingAreas()
  }

  private func refreshTrackingAreas() {
    if let mainTrackingArea {
      view.removeTrackingArea(mainTrackingArea)
    }
    let mainOptions: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect]
    let newMain = NSTrackingArea(rect: view.bounds, options: mainOptions, owner: self, userInfo: nil)
    view.addTrackingArea(newMain)
    mainTrackingArea = newMain

    if let closeTrackingArea {
      closeButton.removeTrackingArea(closeTrackingArea)
    }
    let closeOptions: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect]
    let newClose = NSTrackingArea(
      rect: closeButton.bounds,
      options: closeOptions,
      owner: self,
      userInfo: ["close": true]
    )
    closeButton.addTrackingArea(newClose)
    closeTrackingArea = newClose
  }

  func configure(
    with tab: TabModel,
    iconSize: CGFloat,
    selected: Bool,
    closable: Bool,
    iconImage: NSImage? = nil
  ) {
    isTabSelected = selected
    isClosable = closable

    let isHomeTab = tab.icon == "house"

    // Toggle layout constraints for home vs regular tabs
    titleLeadingConstraint.constant = isHomeTab ? 0 : Style.iconTrailingPadding
    titleLeadingConstraint.isActive = true
    closeLeadingConstraint.constant = isHomeTab ? 0 : 6
    closeLeadingConstraint.isActive = true
    closeTrailingConstraint.isActive = true
    iconTrailingConstraintForHome.isActive = isHomeTab

    if isHomeTab {
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
      iconImageView.contentTintColor = .labelColor
      titleLabel.stringValue = ""
      titleLabel.isHidden = true
      closeWidthConstraint.constant = 0
      closeButton.isHidden = true
    } else {
      // Other tabs: square badge with soft corners
      iconWidthConstraint.constant = iconSize
      iconHeightConstraint.constant = iconSize
      iconImageView.layer?.cornerRadius = Style.iconCornerRadius
      iconImageView.layer?.backgroundColor = iconImage == nil
        ? NSColor.systemGray.withAlphaComponent(0.3).cgColor
        : NSColor.clear.cgColor
      iconImageView.imageScaling = .scaleProportionallyUpOrDown
      iconImageView.image = iconImage
      titleLabel.stringValue = tab.title
      titleLabel.isHidden = false
      closeWidthConstraint.constant = 14
      closeButton.isHidden = false
    }

    titleLabel.stringValue = isHomeTab ? "" : tab.title
    updateAppearance(animated: false)
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    refreshTrackingAreas()
    updateBackgroundShape()
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

  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    if event.trackingArea == closeTrackingArea {
      isCloseHovered = true
    } else {
      isHovered = true
    }
    updateAppearance()
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    if event.trackingArea == closeTrackingArea {
      isCloseHovered = false
    } else {
      isHovered = false
    }
    updateAppearance()
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    isHovered = false
    isCloseHovered = false
    isTabSelected = false
    isClosable = true
    updateAppearance(animated: false)
  }

  private func updateAppearance(animated _: Bool = false) {
    updateBackgroundShape()

    let showClose = isHovered && isClosable
    let targetCloseWidth: CGFloat = showClose ? 14 : 0
    let targetCloseLeading: CGFloat = showClose ? 6 : 0
    let targetCloseTrailing: CGFloat = showClose ? -6 : 0
    let closeAlpha: CGFloat = showClose ? 1 : 0

    let shadowAlpha: CGFloat
    let backgroundAlpha: CGFloat
    let hoverAlpha: CGFloat

    if isTabSelected {
      shadowAlpha = 1
      backgroundAlpha = 1
      hoverAlpha = 0
      if NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
        backgroundView.layer?.backgroundColor = NSColor.darkGray.withAlphaComponent(0.3).cgColor
      } else {
        backgroundView.layer?.backgroundColor = NSColor.white.cgColor
      }
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

    let closeBackground = isCloseHovered
      ? NSColor.systemGray.withAlphaComponent(0.18).cgColor
      : NSColor.clear.cgColor
    closeButton.wantsLayer = true
    closeButton.layer?.cornerRadius = 4

    closeWidthConstraint.constant = targetCloseWidth
    closeLeadingConstraint.constant = targetCloseLeading
    closeTrailingConstraint.constant = targetCloseTrailing

    closeButton.alphaValue = closeAlpha
    closeButton.isHidden = !showClose
    closeButton.layer?.backgroundColor = closeBackground

    shadowView.alphaValue = shadowAlpha
    backgroundView.alphaValue = backgroundAlpha
    hoverBackgroundView.alphaValue = hoverAlpha

    view.layoutSubtreeIfNeeded()
  }

  @objc private func closeButtonTapped() {
    onClose?()
  }
}
