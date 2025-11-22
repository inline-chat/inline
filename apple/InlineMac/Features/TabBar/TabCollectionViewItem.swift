import AppKit

class TabCollectionViewItem: NSCollectionViewItem {
  var onClose: (() -> Void)?

  // MARK: - Style Constants

  private enum Style {
    // Selected tab background (extends beyond bounds with melting effect)
    static let selectedTopRadius: CGFloat = 8
    static let selectedBottomCurveHeight: CGFloat = 10
    static let selectedBackgroundExtension: CGFloat = 11

    // Hover background (stays within bounds)
    static let hoverCornerRadius: CGFloat = 8
    static let hoverInset: CGFloat = Theme.tabBarItemInset

    // Animation
    static let animationDuration: TimeInterval = 0.15
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
  private let iconImageView = NSImageView()
  private let titleLabel = NSTextField(labelWithString: "")
  private let closeButton = NSButton()

  override init(nibName _: NSNib.Name?, bundle _: Bundle?) {
    super.init(nibName: nil, bundle: nil)
    setupViews()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setupViews()
  }

  private func setupViews() {
    view = NSView()
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
    iconImageView.imageScaling = .scaleProportionallyDown
    iconImageView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(iconImageView)

    titleLabel.font = NSFont.systemFont(ofSize: 13)
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
    closeButton.target = self
    closeButton.action = #selector(closeButtonTapped)
    closeButton.alphaValue = 0
    let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .medium)
    closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?
      .withSymbolConfiguration(config)
    view.addSubview(closeButton)

    iconWidthConstraint = iconImageView.widthAnchor.constraint(equalToConstant: 16)
    iconHeightConstraint = iconImageView.heightAnchor.constraint(equalToConstant: 16)

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

      iconImageView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
      iconImageView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      iconWidthConstraint,
      iconHeightConstraint,

      titleLabel.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 6),
      titleLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),

      closeButton.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 6),
      closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
      closeButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      closeButton.widthAnchor.constraint(equalToConstant: 14),
      closeButton.heightAnchor.constraint(equalToConstant: 14),
    ])

    let trackingArea = NSTrackingArea(
      rect: view.bounds,
      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    view.addTrackingArea(trackingArea)
  }

  func configure(with tab: TabModel, iconSize: CGFloat, selected: Bool, closable: Bool) {
    isTabSelected = selected
    isClosable = closable

    let isHomeTab = tab.icon == "house"

    if isHomeTab {
      // Home tab: 20x20 icon (4px larger), no circle background
      iconWidthConstraint.constant = 20
      iconHeightConstraint.constant = 20
      iconImageView.layer?.cornerRadius = 0
      iconImageView.layer?.backgroundColor = NSColor.clear.cgColor

      let config = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
      iconImageView.image = NSImage(systemSymbolName: tab.icon, accessibilityDescription: nil)?
        .withSymbolConfiguration(config)
    } else {
      // Other tabs: 18x18 empty circle
      iconWidthConstraint.constant = 18
      iconHeightConstraint.constant = 18
      iconImageView.layer?.cornerRadius = 9
      iconImageView.layer?.backgroundColor = NSColor.systemGray.withAlphaComponent(0.3).cgColor
      iconImageView.image = nil
    }

    titleLabel.stringValue = tab.title
    updateAppearance()
  }

  override func viewDidLayout() {
    super.viewDidLayout()
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
    isHovered = true
    updateAppearance()
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    isHovered = false
    updateAppearance()
  }

  private func updateAppearance() {
    updateBackgroundShape()

    NSAnimationContext.runAnimationGroup { context in
      context.duration = Style.animationDuration

      closeButton.animator().alphaValue = (isHovered && isClosable) ? 1 : 0

      if isTabSelected {
        // Show selected background with custom shape and shadow/glow
        shadowView.animator().alphaValue = 1
        backgroundView.animator().alphaValue = 1
        hoverBackgroundView.animator().alphaValue = 0

        if NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
          backgroundView.layer?.backgroundColor = NSColor.darkGray.withAlphaComponent(0.3).cgColor
        } else {
          backgroundView.layer?.backgroundColor = NSColor.white.cgColor
        }
      } else if isHovered {
        // Show hover background with simple rounded corners
        shadowView.animator().alphaValue = 0
        backgroundView.animator().alphaValue = 0
        hoverBackgroundView.animator().alphaValue = 1
        hoverBackgroundView.layer?.backgroundColor = NSColor.systemGray.withAlphaComponent(0.15).cgColor
      } else {
        // Hide all backgrounds
        shadowView.animator().alphaValue = 0
        backgroundView.animator().alphaValue = 0
        hoverBackgroundView.animator().alphaValue = 0
      }
    }
  }

  @objc private func closeButtonTapped() {
    onClose?()
  }
}
