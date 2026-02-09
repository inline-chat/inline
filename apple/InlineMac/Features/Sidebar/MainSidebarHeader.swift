import AppKit
import Combine
import InlineKit
import InlineMacUI
import Observation

final class MainSidebarHeaderView: NSView {
  private static let defaultHeight: CGFloat = MainSidebar.itemHeight

  private let dependencies: AppDependencies
  private let nav2: Nav2
  private let spacePickerState: SpacePickerState

  // MainSidebar hosts the overlay; header reports visibility for positioning.
  var onSpacePickerChange: ((Bool) -> Void)?

  private var cancellables: Set<AnyCancellable> = []
  private var didSetupNavObservation: Bool = false

  private lazy var rowView: MainSidebarHeaderRowView = {
    let view = MainSidebarHeaderRowView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.onToggleSpacePicker = { [weak self] in
      guard let self else { return }
      self.spacePickerState.isVisible.toggle()
    }
    view.onOpenMenu = { [weak self] in
      self?.presentSpaceMenu()
    }
    return view
  }()

  var spacePickerAnchorView: NSView {
    rowView.spacePickerAnchorView
  }

  init(dependencies: AppDependencies, spacePickerState: SpacePickerState) {
    self.dependencies = dependencies
    self.nav2 = dependencies.nav2 ?? Nav2()
    self.spacePickerState = spacePickerState
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    setupView()
    setupBindings()
    updateUI()
    setupNavObservation()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupView() {
    addSubview(rowView)

    NSLayoutConstraint.activate([
      rowView.leadingAnchor.constraint(equalTo: leadingAnchor),
      rowView.trailingAnchor.constraint(equalTo: trailingAnchor),
      rowView.topAnchor.constraint(equalTo: topAnchor),
      rowView.bottomAnchor.constraint(equalTo: bottomAnchor),
      heightAnchor.constraint(equalToConstant: Self.defaultHeight),
    ])
  }

  private func setupBindings() {
    spacePickerState.$isVisible
      .removeDuplicates()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] isVisible in
        guard let self else { return }
        self.rowView.setExpanded(isVisible)
        self.onSpacePickerChange?(isVisible)
      }
      .store(in: &cancellables)
  }

  private func setupNavObservation() {
    guard didSetupNavObservation == false else { return }
    didSetupNavObservation = true
    observeNav2()
  }

  private func observeNav2() {
    withObservationTracking { [weak self] in
      guard let self else { return }
      _ = nav2.activeTab
    } onChange: { [weak self] in
      // Re-arm observation immediately to avoid missing rapid successive changes.
      self?.observeNav2()
      Task { @MainActor [weak self] in
        guard let self else { return }
        // Mirror the previous SwiftUI behavior: switching tabs collapses the picker.
        self.spacePickerState.isVisible = false
        self.updateUI()
      }
    }
  }

  private func updateUI() {
    let item = item(for: nav2.activeTab)
    rowView.configure(item: item, showsManageButton: item.kind == .space)
    rowView.setExpanded(spacePickerState.isVisible)
  }

  private func item(for activeTab: TabId) -> SpaceHeaderItem {
    switch activeTab {
      case .home:
        return .home
      case let .space(id, name):
        let fallback = ObjectCache.shared.getSpace(id: id) ?? Space(id: id, name: name, date: Date())
        return SpaceHeaderItem(space: fallback)
    }
  }

  private func presentSpaceMenu() {
    guard case let .space(spaceId, _) = nav2.activeTab else { return }
    let menu = NSMenu()

    // Section header so it's obvious the actions apply to the active space.
    let spaceTitle = item(for: nav2.activeTab).title
    let headerItem = NSMenuItem(title: spaceTitle, action: nil, keyEquivalent: "")
    headerItem.isEnabled = false
    headerItem.attributedTitle = NSAttributedString(
      string: spaceTitle,
      attributes: [
        .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
        .foregroundColor: NSColor.secondaryLabelColor,
      ]
    )

    let membersItem = NSMenuItem(title: "Members", action: #selector(menuMembers), keyEquivalent: "")
    membersItem.target = self
    membersItem.representedObject = spaceId

    let inviteItem = NSMenuItem(title: "Invite", action: #selector(menuInvite), keyEquivalent: "")
    inviteItem.target = self
    inviteItem.representedObject = spaceId

    let integrationsItem = NSMenuItem(title: "Integrations", action: #selector(menuIntegrations), keyEquivalent: "")
    integrationsItem.target = self
    integrationsItem.representedObject = spaceId

    menu.items = [headerItem, .separator(), membersItem, inviteItem, integrationsItem]

    // Pop up relative to the click event when possible so positioning feels native.
    let anchorView = rowView.menuButtonAnchorView ?? rowView
    if let event = NSApp.currentEvent {
      NSMenu.popUpContextMenu(menu, with: event, for: anchorView)
    } else {
      let point = NSPoint(x: 0, y: anchorView.bounds.maxY + 6)
      menu.popUp(positioning: nil, at: point, in: anchorView)
    }
  }

  @objc private func menuMembers(_ sender: NSMenuItem) {
    guard let spaceId = sender.representedObject as? Int64 else { return }
    nav2.navigate(to: .members(spaceId: spaceId))
  }

  @objc private func menuInvite(_ sender: NSMenuItem) {
    _ = sender.representedObject as? Int64
    nav2.navigate(to: .inviteToSpace)
  }

  @objc private func menuIntegrations(_ sender: NSMenuItem) {
    guard let spaceId = sender.representedObject as? Int64 else { return }
    nav2.navigate(to: .spaceIntegrations(spaceId: spaceId))
  }
}

private final class MainSidebarHeaderRowView: NSView {
  private enum Metrics {
    static let rowHeight: CGFloat = MainSidebar.itemHeight
    static let rowCornerRadius: CGFloat = 10

    // Picker background should align with the list rows below (which are inset by outerEdgeInsets only).
    // HeaderView itself is already inset by outerEdgeInsets, so the picker can go flush to this view.
    static let pickerTrailingPadding: CGFloat = 0
    // Keep the dots button aligned with other trailing accessory buttons in the sidebar (inset).
    static let manageButtonTrailingPadding: CGFloat = MainSidebar.innerEdgeInsets
    static let pickerVerticalPadding: CGFloat = 0
    static let pickerTrailingOverlaySpacing: CGFloat = 6

    static let iconSize: CGFloat = Theme.sidebarTitleIconSize
    static let iconTrailingPadding: CGFloat = MainSidebar.iconTrailingPadding

    static let manageButtonSize: CGFloat = 24
    static let manageButtonCornerRadius: CGFloat = 8
    static let manageButtonIconSize: CGFloat = 14
  }

  var onToggleSpacePicker: (() -> Void)?
  var onOpenMenu: (() -> Void)?

  private var item: SpaceHeaderItem = .home
  private var showsManageButton: Bool = false
  private var isHovering: Bool = false { didSet { updateManageButtonVisibility() } }
  private var trackingAreaRef: NSTrackingArea?

  private let pickerControl = MainSidebarHeaderPickerControl()

  private let manageButton = MainSidebarHeaderIconButton(
    symbolName: "ellipsis",
    accessibilityLabel: "Space settings"
  )

  var menuButtonAnchorView: NSView? { manageButton }
  var spacePickerAnchorView: NSView { pickerControl }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    translatesAutoresizingMaskIntoConstraints = false
    setupView()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(item: SpaceHeaderItem, showsManageButton: Bool) {
    self.item = item
    self.showsManageButton = showsManageButton
    pickerControl.configure(item: item)
    pickerControl.trailingAccessoryInset = showsManageButton
      ? (
        Metrics.manageButtonTrailingPadding
          + Metrics.manageButtonSize
          + Metrics.pickerTrailingOverlaySpacing
      )
      : 0
    updateManageButtonVisibility()
  }

  func setExpanded(_ expanded: Bool) {
    pickerControl.isExpanded = expanded
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingAreaRef {
      removeTrackingArea(trackingAreaRef)
    }
    let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect]
    let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
    addTrackingArea(area)
    trackingAreaRef = area
  }

  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    isHovering = true
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    isHovering = false
  }

  private func setupView() {
    pickerControl.translatesAutoresizingMaskIntoConstraints = false
    pickerControl.target = self
    pickerControl.action = #selector(handlePicker)
    // We want the control to stretch full-width like sidebar rows.
    pickerControl.setContentHuggingPriority(.defaultLow, for: .horizontal)
    pickerControl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    manageButton.translatesAutoresizingMaskIntoConstraints = false
    manageButton.target = self
    manageButton.action = #selector(handleMenuButton)
    manageButton.setContentHuggingPriority(.required, for: .horizontal)
    manageButton.setContentCompressionResistancePriority(.required, for: .horizontal)

    addSubview(pickerControl)
    addSubview(manageButton)
    NSLayoutConstraint.activate([
      // Match the old insets: headerView is already inset by outerEdgeInsets.
      // Picker control has its own internal padding; avoid double-insetting on the leading edge.
      pickerControl.leadingAnchor.constraint(equalTo: leadingAnchor),
      pickerControl.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.pickerTrailingPadding),
      pickerControl.centerYAnchor.constraint(equalTo: centerYAnchor),
      pickerControl.heightAnchor.constraint(equalToConstant: Metrics.rowHeight),

      // Place the "more" button on top of the picker, aligned to the trailing edge.
      manageButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.manageButtonTrailingPadding),
      manageButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      manageButton.widthAnchor.constraint(equalToConstant: Metrics.manageButtonSize),
      manageButton.heightAnchor.constraint(equalToConstant: Metrics.manageButtonSize),
    ])
  }

  private func updateManageButtonVisibility() {
    // Only show the dots menu affordance on hover (and only for space tabs).
    manageButton.isHidden = !(showsManageButton && isHovering)
  }

  @objc private func handlePicker() {
    onToggleSpacePicker?()
  }

  @objc private func handleMenuButton() {
    onOpenMenu?()
  }
}

private final class MainSidebarHeaderPickerControl: NSControl {
  private enum Metrics {
    static let cornerRadius: CGFloat = 10
    static let iconSize: CGFloat = Theme.sidebarTitleIconSize
    static let iconTrailingPadding: CGFloat = MainSidebar.iconTrailingPadding
    static let horizontalPadding: CGFloat = 8
    static let height: CGFloat = MainSidebar.itemHeight
  }

  /// Extra trailing space reserved for an overlaid accessory (e.g. the "more" button).
  /// This keeps the title from rendering underneath the overlay while allowing the control
  /// background to extend to the trailing edge.
  var trailingAccessoryInset: CGFloat = 0 {
    didSet { updateContentInsets() }
  }

  var isExpanded: Bool = false {
    didSet { updateAppearance() }
  }

  private var isHovering: Bool = false {
    didSet { updateAppearance() }
  }

  private var isPressed: Bool = false {
    didSet { updateAppearance() }
  }

  private var trackingAreaRef: NSTrackingArea?

  private let iconContainer = NSView()
  private let homeIconView = NSImageView()
  private let spaceAvatarView = SpaceAvatarView(space: nil, size: Metrics.iconSize)

  private let titleLabel: NSTextField = {
    let label = NSTextField(labelWithString: "")
    label.font = MainSidebar.font
    label.lineBreakMode = .byTruncatingTail
    label.usesSingleLineMode = true
    label.translatesAutoresizingMaskIntoConstraints = false
    return label
  }()

  private var contentTrailingConstraint: NSLayoutConstraint?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    translatesAutoresizingMaskIntoConstraints = false
    setupView()
    updateAppearance()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var intrinsicContentSize: NSSize {
    // Width should be as small as possible while fitting icon+title.
    let titleWidth = titleLabel.intrinsicContentSize.width
    let contentWidth = Metrics.iconSize
      + Metrics.iconTrailingPadding
      + titleWidth
      + (Metrics.horizontalPadding * 2)
      + trailingAccessoryInset
    return NSSize(width: contentWidth, height: Metrics.height)
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateAppearance()
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingAreaRef {
      removeTrackingArea(trackingAreaRef)
    }
    let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect]
    let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
    addTrackingArea(area)
    trackingAreaRef = area
  }

  override func mouseEntered(with _: NSEvent) {
    isHovering = true
  }

  override func mouseExited(with _: NSEvent) {
    isHovering = false
  }

  override func mouseDown(with _: NSEvent) {
    isPressed = true
  }

  override func mouseDragged(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    isPressed = bounds.contains(point)
  }

  override func mouseUp(with event: NSEvent) {
    defer { isPressed = false }
    let point = convert(event.locationInWindow, from: nil)
    guard bounds.contains(point) else { return }
    _ = sendAction(action, to: target)
  }

  func configure(item: SpaceHeaderItem) {
    titleLabel.stringValue = item.title

    switch item.kind {
      case .home:
        homeIconView.isHidden = false
        spaceAvatarView.isHidden = true
      case .space:
        homeIconView.isHidden = true
        spaceAvatarView.isHidden = false
        spaceAvatarView.configure(space: item.space, size: Metrics.iconSize)
    }

    invalidateIntrinsicContentSize()
    updateAppearance()
  }

  private func setupView() {
    wantsLayer = true
    layer?.cornerRadius = Metrics.cornerRadius
    layer?.cornerCurve = .continuous
    layer?.masksToBounds = true

    iconContainer.translatesAutoresizingMaskIntoConstraints = false
    iconContainer.wantsLayer = true

    let homeConfig = NSImage.SymbolConfiguration(
      pointSize: Metrics.iconSize * 0.7,
      weight: .semibold
    )
    homeIconView.image = NSImage(systemSymbolName: "house.fill", accessibilityDescription: nil)?
      .withSymbolConfiguration(homeConfig)
    homeIconView.translatesAutoresizingMaskIntoConstraints = false

    spaceAvatarView.translatesAutoresizingMaskIntoConstraints = false

    iconContainer.addSubview(homeIconView)
    iconContainer.addSubview(spaceAvatarView)
    NSLayoutConstraint.activate([
      iconContainer.widthAnchor.constraint(equalToConstant: Metrics.iconSize),
      iconContainer.heightAnchor.constraint(equalToConstant: Metrics.iconSize),

      homeIconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
      homeIconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),

      spaceAvatarView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
      spaceAvatarView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
    ])

    let content = NSStackView()
    content.translatesAutoresizingMaskIntoConstraints = false
    content.orientation = .horizontal
    content.alignment = .centerY
    content.spacing = Metrics.iconTrailingPadding

    content.addArrangedSubview(iconContainer)
    content.addArrangedSubview(titleLabel)

    titleLabel.setContentHuggingPriority(.required, for: .horizontal)
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    addSubview(content)
    let trailing = content.trailingAnchor.constraint(
      equalTo: trailingAnchor,
      constant: -(Metrics.horizontalPadding + trailingAccessoryInset)
    )
    contentTrailingConstraint = trailing
    NSLayoutConstraint.activate([
      content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.horizontalPadding),
      trailing,
      content.topAnchor.constraint(equalTo: topAnchor),
      content.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  private func updateContentInsets() {
    contentTrailingConstraint?.constant = -(Metrics.horizontalPadding + trailingAccessoryInset)
    invalidateIntrinsicContentSize()
    needsLayout = true
  }

  private func updateAppearance() {
    let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let hoverColor: NSColor = isDark
      ? NSColor.white.withAlphaComponent(0.18)
      : NSColor.black.withAlphaComponent(0.06)
    let pressedColor: NSColor = isDark
      ? NSColor.white.withAlphaComponent(0.24)
      : NSColor.black.withAlphaComponent(0.10)

    let backgroundColor: NSColor = if isExpanded {
      Theme.windowContentBackgroundColor.resolvedColor(with: effectiveAppearance)
    } else if isPressed {
      pressedColor
    } else if isHovering {
      hoverColor
    } else {
      NSColor.clear
    }

    // Keep icon/text color stable on hover; only show "active" text when expanded (or pressed).
    let textColor: NSColor = (isExpanded || isPressed) ? .labelColor : .secondaryLabelColor
    layer?.backgroundColor = backgroundColor.cgColor
    titleLabel.textColor = textColor
    homeIconView.contentTintColor = textColor
  }
}

private final class MainSidebarHeaderIconButton: NSButton {
  private enum Metrics {
    static let cornerRadius: CGFloat = 8
    // Match sidebar footer icon sizing.
    static let iconSize: CGFloat = 13
  }

  private let symbolName: String
  private let labelText: String

  init(symbolName: String, accessibilityLabel: String) {
    self.symbolName = symbolName
    labelText = accessibilityLabel
    super.init(frame: .zero)
    setup()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var isHighlighted: Bool {
    didSet { updateBackground() }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateAppearance()
    updateBackground()
  }

  private func setup() {
    wantsLayer = true
    layer?.cornerRadius = Metrics.cornerRadius
    layer?.cornerCurve = .continuous
    setButtonType(.momentaryChange)
    isBordered = false
    bezelStyle = .regularSquare
    imagePosition = .imageOnly
    imageScaling = .scaleProportionallyDown
    focusRingType = .none
    updateAppearance()
    updateBackground()
  }

  private func updateAppearance() {
    // Keep it subtle: smaller and thinner than the default header glyph.
    let config = NSImage.SymbolConfiguration(pointSize: Metrics.iconSize, weight: .regular)
    image = NSImage(systemSymbolName: symbolName, accessibilityDescription: labelText)?
      .withSymbolConfiguration(config)
    // Keep the icon tint stable; the picker underneath already has hover affordance.
    contentTintColor = .tertiaryLabelColor
  }

  override func accessibilityLabel() -> String? {
    labelText
  }

  private func updateBackground() {
    let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let pressedColor: NSColor = isDark
      ? NSColor.white.withAlphaComponent(0.24)
      : NSColor.black.withAlphaComponent(0.10)

    let color: NSColor = if isHighlighted {
      pressedColor
    } else {
      .clear
    }
    layer?.backgroundColor = color.cgColor
  }
}

struct SpaceHeaderItem: Identifiable, Hashable {
  enum Kind {
    case home
    case space
  }

  let kind: Kind
  let space: Space?

  var id: String {
    switch kind {
      case .home:
        "home"
      case .space:
        "space-\(space?.id ?? 0)"
    }
  }

  var title: String {
    switch kind {
      case .home:
        "Home"
      case .space:
        space?.displayName ?? "Untitled Space"
    }
  }

  var spaceId: Int64? { space?.id }

  static var home: SpaceHeaderItem {
    SpaceHeaderItem(kind: .home)
  }

  private init(kind: Kind, space: Space? = nil) {
    self.kind = kind
    self.space = space
  }

  init(space: Space) {
    kind = .space
    self.space = space
  }

  func matches(spaceId: Int64?, isHome: Bool) -> Bool {
    switch kind {
      case .home:
        return isHome
      case .space:
        return spaceId != nil && spaceId == self.spaceId
    }
  }
}
