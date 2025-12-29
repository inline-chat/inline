import AppKit
import Combine
import InlineKit
import InlineMacUI
import Observation

class MainSidebarHeaderView: NSView {
  private static let titleHeight: CGFloat = MainSidebar.itemHeight
  private static let height: CGFloat = MainSidebarHeaderView.titleHeight
  private static let iconSize: CGFloat = Theme.sidebarTitleIconSize
  private static let cornerRadius: CGFloat = 10
  private static let innerPadding: CGFloat = MainSidebar.innerEdgeInsets

  private let dependencies: AppDependencies
  private var nav2: Nav2? { dependencies.nav2 }

  private var currentTabId: TabId?

  private var isHovered = false {
    didSet { updateHoverAppearance() }
  }

  private var hoverColor: NSColor {
    .white.withAlphaComponent(0.2)
  }

  init(dependencies: AppDependencies) {
    self.dependencies = dependencies
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    setupViews()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // Clickable container for space header (with hover background)
  private lazy var spaceContainerView: NSView = {
    let view = NSView()
    view.wantsLayer = true
    view.layer?.cornerRadius = Self.cornerRadius
    view.layer?.masksToBounds = true
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private lazy var textView: NSTextField = {
    let view = NSTextField(labelWithString: "")
    view.font = MainSidebar.font
    view.textColor = .secondaryLabelColor
    view.lineBreakMode = .byTruncatingTail
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private lazy var spaceAvatarView: SpaceAvatarView = {
    SpaceAvatarView(size: Self.iconSize)
  }()

  private lazy var homeIconView: NSImageView = {
    let view = NSImageView()
    view.imageScaling = .scaleProportionallyUpOrDown
    view.translatesAutoresizingMaskIntoConstraints = false
    let config = NSImage.SymbolConfiguration(
      pointSize: Self.iconSize * 0.7,
      weight: .semibold,
      scale: .medium
    )
    view.image = NSImage(systemSymbolName: "house.fill", accessibilityDescription: nil)?
      .withSymbolConfiguration(config)
    view.contentTintColor = .secondaryLabelColor
    return view
  }()

  private func setupViews() {
    addSubview(spaceContainerView)
    addSubview(homeIconView)

    spaceContainerView.addSubview(spaceAvatarView)
    spaceContainerView.addSubview(textView)

    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: MainSidebarHeaderView.height),

      // Space container - aligned with item insets
      spaceContainerView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -Self.innerPadding),
      spaceContainerView.topAnchor.constraint(equalTo: topAnchor),
      spaceContainerView.bottomAnchor.constraint(equalTo: bottomAnchor),

      // Avatar inside container
      spaceAvatarView.leadingAnchor.constraint(equalTo: spaceContainerView.leadingAnchor, constant: Self.innerPadding),
      spaceAvatarView.centerYAnchor.constraint(equalTo: spaceContainerView.centerYAnchor),

      // Text inside container
      textView.leadingAnchor.constraint(equalTo: spaceAvatarView.trailingAnchor, constant: MainSidebar.iconTrailingPadding),
      textView.trailingAnchor.constraint(equalTo: spaceContainerView.trailingAnchor, constant: -Self.innerPadding),
      textView.centerYAnchor.constraint(equalTo: spaceContainerView.centerYAnchor),
      textView.heightAnchor.constraint(lessThanOrEqualToConstant: MainSidebarHeaderView.height - 16),

      // Home icon (not inside container)
      homeIconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0),
      homeIconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      homeIconView.widthAnchor.constraint(equalToConstant: Self.iconSize),
      homeIconView.heightAnchor.constraint(equalToConstant: Self.iconSize),
    ])

    setupClickGesture()
  }

  override func layout() {
    super.layout()

    let activeTab = nav2?.activeTab
    textView.stringValue = activeTab?.tabTitle ?? "Home"

    // Only update icon if tab changed
    guard currentTabId != activeTab else { return }
    currentTabId = activeTab

    updateIcon(for: activeTab)
  }

  private func updateIcon(for tab: TabId?) {
    switch tab {
    case let .space(id, name):
      let space = spaceForAvatar(id: id, fallbackName: name)
      spaceAvatarView.configure(space: space)
      spaceContainerView.isHidden = false
      homeIconView.isHidden = true

    default:
      spaceContainerView.isHidden = true
      homeIconView.isHidden = false
    }
  }

  private func spaceForAvatar(id: Int64, fallbackName: String) -> Space {
    if let space = ObjectCache.shared.getSpace(id: id) {
      return space
    }
    return Space(id: id, name: fallbackName, date: Date())
  }

  // MARK: - Hover Tracking

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach { removeTrackingArea($0) }

    let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect]
    let area = NSTrackingArea(rect: spaceContainerView.frame, options: options, owner: self, userInfo: nil)
    addTrackingArea(area)
  }

  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    guard case .space = currentTabId else { return }
    isHovered = true
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    isHovered = false
  }

  private func updateHoverAppearance() {
    spaceContainerView.effectiveAppearance.performAsCurrentDrawingAppearance {
      spaceContainerView.layer?.backgroundColor = isHovered ? hoverColor.cgColor : .clear
    }
  }

  // MARK: - Click & Menu

  private func setupClickGesture() {
    let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
    spaceContainerView.addGestureRecognizer(click)
  }

  @objc private func handleClick(_ gesture: NSClickGestureRecognizer) {
    guard case let .space(spaceId, _) = currentTabId else { return }
    showSpaceMenu(for: spaceId)
  }

  private func showSpaceMenu(for spaceId: Int64) {
    let menu = NSMenu()

    let membersItem = NSMenuItem(
      title: "Members",
      action: #selector(openMembers(_:)),
      keyEquivalent: ""
    )
    membersItem.target = self
    membersItem.representedObject = spaceId
    membersItem.image = NSImage(systemSymbolName: "person.2", accessibilityDescription: nil)
    menu.addItem(membersItem)

    let inviteItem = NSMenuItem(
      title: "Invite",
      action: #selector(openInvite(_:)),
      keyEquivalent: ""
    )
    inviteItem.target = self
    inviteItem.representedObject = spaceId
    inviteItem.image = NSImage(systemSymbolName: "person.badge.plus", accessibilityDescription: nil)
    menu.addItem(inviteItem)

    let integrationsItem = NSMenuItem(
      title: "Integrations",
      action: #selector(openIntegrations(_:)),
      keyEquivalent: ""
    )
    integrationsItem.target = self
    integrationsItem.representedObject = spaceId
    integrationsItem.image = NSImage(systemSymbolName: "app.connected.to.app.below.fill", accessibilityDescription: nil)
    menu.addItem(integrationsItem)

    // Show menu below the space container
    let location = NSPoint(x: 0, y: -4)
    menu.popUp(positioning: nil, at: location, in: spaceContainerView)
  }

  @objc private func openMembers(_ sender: NSMenuItem) {
    guard let spaceId = sender.representedObject as? Int64 else { return }
    nav2?.navigate(to: .members(spaceId: spaceId))
  }

  @objc private func openInvite(_ sender: NSMenuItem) {
    guard let spaceId = sender.representedObject as? Int64 else { return }
    nav2?.navigate(to: .inviteToSpace)
  }

  @objc private func openIntegrations(_ sender: NSMenuItem) {
    guard let spaceId = sender.representedObject as? Int64 else { return }
    nav2?.navigate(to: .spaceIntegrations(spaceId: spaceId))
  }
}
