import AppKit
import InlineKit
import InlineMacUI
import InlineUI
import Observation
import QuartzCore
import SwiftUI

@MainActor
struct SidebarNativeRowConfiguration {
  struct InteractionPresentation: Equatable {
    enum DragMode: Equatable {
      case idle
      case lifted
      case dropTarget
    }

    let selected: Bool
    let dragMode: DragMode

    static let idle = Self(selected: false, dragMode: .idle)
  }
  struct Avatar: Equatable {
    let userID: Int64
    let firstName: String?
    let lastName: String?
    let email: String?
    let username: String?
    let stableAvatarIdentity: String?
    let remoteURL: URL?
    let localURL: URL?

    init(_ descriptor: ChatListUserAvatarDescriptor) {
      userID = descriptor.userID
      firstName = descriptor.firstName
      lastName = descriptor.lastName
      email = descriptor.email
      username = descriptor.username
      stableAvatarIdentity = descriptor.stableAvatarIdentity
      remoteURL = descriptor.remoteURL
      localURL = descriptor.localURL
    }

    init(_ user: InlineKit.User) {
      userID = user.id
      firstName = user.firstName
      lastName = user.lastName
      email = user.email
      username = user.username
      stableAvatarIdentity = user.stableAvatarIdentity
      remoteURL = user.getRemoteURL()
      localURL = user.getLocalURL()
    }
  }

  struct Navigation {
    enum IconStyle {
      case standard
      case newThread
    }

    let title: String
    let systemImage: String
    let iconStyle: IconStyle
    let selected: Bool
    let titleDimmed: Bool
    let size: SidebarItemSize
    let prominentUnreadCount: Int
    let otherUnreadCount: Int
    let avatars: [Avatar]
    let accessibilityValue: String
    let action: () -> Void
  }

  struct Header {
    enum Style {
      case archive
      case timeline
      case section
    }

    let title: String
    let style: Style
    let isExpanded: Bool?
    let topSpacing: CGFloat
    let onToggle: (() -> Void)?
    let onCleanUp: (() -> Void)?
    let onCloseAll: (() -> Void)?
  }

  struct PinDropGuide {
    let dimsInstruction: Bool
  }

  struct ChatActions {
    let open: () -> Void
    let close: () -> Void
    let persist: () -> Void
    let toggleDisclosure: () -> Void
    let openInNewTab: () -> Void
    let openInNewWindow: () -> Void
    let rename: () -> Void
    let togglePin: () -> Void
    let toggleReadUnread: () -> Void
    let folderMenu: () -> SidebarChatFolderMenu?
  }

  /// Immutable render input for one native chat row. Collection hierarchy,
  /// persistence, and navigation remain outside the renderer; the row receives
  /// only the values it paints or exposes through its menu/accessibility surface.
  struct ChatPresentation: Equatable {
    let peerID: Peer
    let parentChatID: Int64?
    let title: String
    let preview: String
    let unread: Bool
    let unreadCount: Int
    let unreadMark: Bool
    let prominentUnreadDot: Bool
    let pinned: Bool
    let identity: ChatListIdentityDescriptor?

    init(_ item: SidebarViewModel.Item) {
      peerID = item.peerId
      parentChatID = item.parentChatId
      title = item.title
      preview = item.preview
      unread = item.unread
      unreadCount = item.unreadCount
      unreadMark = item.unreadMark
      prominentUnreadDot = item.prominentUnreadDot
      pinned = item.pinned
      identity = item.identity
    }

    init(
      peerID: Peer,
      parentChatID: Int64? = nil,
      title: String,
      preview: String = "",
      unread: Bool = false,
      unreadCount: Int = 0,
      unreadMark: Bool = false,
      prominentUnreadDot: Bool = false,
      pinned: Bool = false,
      identity: ChatListIdentityDescriptor? = nil
    ) {
      self.peerID = peerID
      self.parentChatID = parentChatID
      self.title = title
      self.preview = preview
      self.unread = unread
      self.unreadCount = max(unreadCount, 0)
      self.unreadMark = unreadMark
      self.prominentUnreadDot = prominentUnreadDot
      self.pinned = pinned
      self.identity = identity
    }
  }

  struct Chat {
    let presentation: ChatPresentation
    let selected: Bool
    let titleDimmed: Bool
    let size: SidebarItemSize
    let unreadBadgeStyle: UnreadBadgeStyle
    let showsCloseButton: Bool
    let isTemporary: Bool
    let isDropTargeted: Bool
    let forceHoverAppearance: Bool
    let indentationLevel: Int
    let showsIcon: Bool
    let disclosureExpanded: Bool?
    let actions: ChatActions
  }

  struct FolderPresentation: Equatable {
    let title: String
    let childCount: Int
    let unreadCount: Int

    init(_ folder: SidebarProjectedFolder) {
      title = folder.title
      childCount = folder.childCount
      unreadCount = folder.unreadCount
    }
  }

  struct FolderActions {
    let toggleDisclosure: () -> Void
    let close: () -> Void
    let ungroup: () -> Void
  }

  struct Folder {
    let presentation: FolderPresentation
    let titleDimmed: Bool
    let size: SidebarItemSize
    let disclosureExpanded: Bool
    let forceHoverAppearance: Bool
    let actions: FolderActions
  }

  struct EmptyState {
    let title: String
    let systemImage: String
    let actionTitle: String?
    let action: (() -> Void)?
  }

  enum Content {
    case navigation(Navigation)
    case header(Header)
    case pinDropGuide(PinDropGuide)
    case chat(Chat)
    case folder(Folder)
    case emptyState(EmptyState)
  }

  let rowID: SidebarCollectionRow.ID
  let content: Content
  let animatesChanges: Bool

  var interactionPresentation: InteractionPresentation {
    switch content {
    case let .navigation(value):
      InteractionPresentation(selected: value.selected, dragMode: .idle)
    case let .chat(value):
      InteractionPresentation(
        selected: value.selected,
        dragMode: value.isDropTargeted ? .dropTarget
          : (value.forceHoverAppearance ? .lifted : .idle)
      )
    case let .folder(value):
      InteractionPresentation(
        selected: false,
        dragMode: value.forceHoverAppearance ? .lifted : .idle
      )
    case .header, .pinDropGuide, .emptyState:
      .idle
    }
  }
}

/// The close control deliberately separates input and visual geometry. Its
/// AppKit hit target can stay generous without consuming more title/preview
/// width than the 16-point SwiftUI reference button.
private enum SidebarNativeChatRowMetrics {
  static let closeVisualSize: CGFloat = 16
  static let closeHitSize: CGFloat = 28
  static let closeTextSpacing: CGFloat = 8
}

private enum SidebarNativeFolderRowMetrics {
  static let accessoryHitSize: CGFloat = 28
  static let disclosureWidth: CGFloat = 24
}

/// A narrow SwiftUI rendering leaf inside an AppKit-owned row. The hosting
/// boundary never participates in input or accessibility; AppKit continues to
/// own reuse, geometry, hit testing, menus, gestures, and semantic actions.
@MainActor
private final class SidebarNativeHostedVisualView: NSHostingView<AnyView> {
  convenience init() {
    self.init(rootView: AnyView(EmptyView()))
  }

  required init(rootView: AnyView) {
    super.init(rootView: rootView)
    sizingOptions = []
    wantsLayer = true
    clipsToBounds = true
    setAccessibilityElement(false)
    setAccessibilityHidden(true)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure<Content: View>(@ViewBuilder content: () -> Content) {
    rootView = AnyView(content().allowsHitTesting(false).accessibilityHidden(true))
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    rootView = AnyView(EmptyView())
  }

  override func hitTest(_: NSPoint) -> NSView? {
    nil
  }
}

/// Native renderer mounted inside the existing reusable collection item. It
/// owns only presentation and input; semantic identity and collection state
/// remain in `SidebarCollectionBodyController`.
@MainActor
final class SidebarNativeRowView: NSView {
  private enum ContentKind {
    case navigation
    case header
    case pinDropGuide
    case chat
    case folder
    case emptyState
  }

  private var contentView: SidebarNativeContentView?
  private var contentKind: ContentKind?
  private(set) var representedRowID: SidebarCollectionRow.ID?
  private var isLayoutVisible = true
  private var suppressesNextConfigurationAnimations = false

  override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    clipsToBounds = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(_ configuration: SidebarNativeRowConfiguration) {
    representedRowID = configuration.rowID
    let animatesChanges = configuration.animatesChanges
      && !suppressesNextConfigurationAnimations
    let configuredContentView: SidebarNativeContentView

    switch configuration.content {
    case let .navigation(value):
      guard let view = contentView(for: .navigation) as? SidebarNativeNavigationRowView else {
        assertionFailure("Unexpected native navigation row view")
        return
      }
      configuredContentView = view
      view.allowsAnimations = animatesChanges
      view.setInteractionPresentation(configuration.interactionPresentation)
      view.configure(value)
    case let .header(value):
      guard let view = contentView(for: .header) as? SidebarNativeHeaderRowView else {
        assertionFailure("Unexpected native header row view")
        return
      }
      configuredContentView = view
      view.allowsAnimations = animatesChanges
      view.setInteractionPresentation(configuration.interactionPresentation)
      view.configure(value)
    case let .pinDropGuide(value):
      guard let view = contentView(for: .pinDropGuide) as? SidebarNativePinDropGuideRowView else {
        assertionFailure("Unexpected native pin-drop-guide row view")
        return
      }
      configuredContentView = view
      view.allowsAnimations = animatesChanges
      view.setInteractionPresentation(configuration.interactionPresentation)
      view.configure(value)
    case let .chat(value):
      guard let view = contentView(for: .chat) as? SidebarNativeChatRowView else {
        assertionFailure("Unexpected native chat row view")
        return
      }
      configuredContentView = view
      view.allowsAnimations = animatesChanges
      view.setInteractionPresentation(configuration.interactionPresentation)
      view.configure(value)
    case let .folder(value):
      guard let view = contentView(for: .folder) as? SidebarNativeFolderRowView else {
        assertionFailure("Unexpected native folder row view")
        return
      }
      configuredContentView = view
      view.allowsAnimations = animatesChanges
      view.setInteractionPresentation(configuration.interactionPresentation)
      view.configure(value)
    case let .emptyState(value):
      guard let view = contentView(for: .emptyState) as? SidebarNativeEmptyStateRowView else {
        assertionFailure("Unexpected native empty-state row view")
        return
      }
      configuredContentView = view
      view.allowsAnimations = animatesChanges
      view.setInteractionPresentation(configuration.interactionPresentation)
      view.configure(value)
    }

    configuredContentView.setLayoutVisibility(isLayoutVisible)
    suppressesNextConfigurationAnimations = false
    needsLayout = true
  }

  func setLayoutVisibility(_ isVisible: Bool) {
    isLayoutVisible = isVisible
    contentView?.setLayoutVisibility(isVisible)
  }

  /// One explicit mechanics seam for collection-owned selection and drag
  /// presentation. Rows retain their own physical hover/press lifecycle.
  func setInteractionPresentation(
    _ presentation: SidebarNativeRowConfiguration.InteractionPresentation
  ) {
    contentView?.setInteractionPresentation(presentation)
  }

  func blocksReorder(at point: NSPoint) -> Bool {
    guard isLayoutVisible, let contentView else { return true }
    return contentView.blocksReorder(at: contentView.convert(point, from: self))
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    representedRowID = nil
    isLayoutVisible = false
    suppressesNextConfigurationAnimations = true
    // Reuse is the hot scrolling path. Keep the same-kind native subtree and
    // its narrow SwiftUI visual hosts attached to the window; the next
    // configuration overwrites every semantic value. Removing this subtree on
    // every dequeue forces NSHostingView/AttributeGraph teardown and rebuild.
    contentView?.setLayoutVisibility(false)
    setAccessibilityHidden(true)
  }

  override func layout() {
    super.layout()
    contentView?.frame = bounds
    contentView?.recomputePointerLocation()
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard isLayoutVisible else { return nil }
    return super.hitTest(point)
  }

  private func contentView(for kind: ContentKind) -> SidebarNativeContentView {
    if contentKind == kind, let contentView {
      return contentView
    }

    contentView?.prepareForReuse()
    contentView?.removeFromSuperview()

    let next: SidebarNativeContentView = switch kind {
    case .navigation:
      SidebarNativeNavigationRowView()
    case .header:
      SidebarNativeHeaderRowView()
    case .pinDropGuide:
      SidebarNativePinDropGuideRowView()
    case .chat:
      SidebarNativeChatRowView()
    case .folder:
      SidebarNativeFolderRowView()
    case .emptyState:
      SidebarNativeEmptyStateRowView()
    }
    next.frame = bounds
    next.autoresizingMask = [.width, .height]
    addSubview(next)
    contentView = next
    contentKind = kind
    setAccessibilityHidden(false)
    return next
  }
}

@MainActor
private class SidebarNativeContentView: NSView {
  private(set) var isLayoutVisible = true
  private(set) var interactionPresentation = SidebarNativeRowConfiguration
    .InteractionPresentation.idle
  var allowsAnimations = true

  override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    setInteractionPresentation(.idle)
    setLayoutVisibility(false)
  }

  func setLayoutVisibility(_ isVisible: Bool) {
    isLayoutVisible = isVisible
    setAccessibilityHidden(!isVisible)
  }

  func setInteractionPresentation(
    _ presentation: SidebarNativeRowConfiguration.InteractionPresentation
  ) {
    interactionPresentation = presentation
  }

  func recomputePointerLocation() {}
  func blocksReorder(at _: NSPoint) -> Bool { false }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard isLayoutVisible else { return nil }
    return super.hitTest(point)
  }
}

@MainActor
private class SidebarNativeInteractiveContentView: SidebarNativeContentView {
  enum InteractionTarget: Equatable {
    case primary
    case accessory(Int)
  }

  var primaryAction: (() -> Void)?
  var doubleClickAction: (() -> Void)?
  private var trackingArea: NSTrackingArea?
  private var mouseDownPoint: NSPoint?
  private var capturedInteractionTarget: InteractionTarget?
  private(set) var isHovered = false
  private(set) var hoveredInteractionTarget: InteractionTarget?
  private(set) var pressedInteractionTarget: InteractionTarget?

  var isPrimaryPressed: Bool {
    pressedInteractionTarget == .primary
  }


  var hasHoverPresentation: Bool {
    isHovered || interactionPresentation.dragMode != .idle
  }

  var hasSelectedPresentation: Bool {
    interactionPresentation.selected || isPrimaryPressed
  }

  override func setInteractionPresentation(
    _ presentation: SidebarNativeRowConfiguration.InteractionPresentation
  ) {
    guard interactionPresentation != presentation else { return }
    super.setInteractionPresentation(presentation)
    hoverDidChange()
    pressDidChange()
    interactionPresentationDidChange()
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea {
      removeTrackingArea(trackingArea)
    }
    let trackingArea = NSTrackingArea(
      rect: .zero,
      options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
      owner: self
    )
    addTrackingArea(trackingArea)
    self.trackingArea = trackingArea
    recomputePointerLocation()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    recomputePointerLocation()
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow == nil {
      cancelPointerInteraction()
    }
    super.viewWillMove(toWindow: newWindow)
  }

  override func mouseEntered(with _: NSEvent) {
    recomputePointerLocation()
  }

  override func mouseExited(with _: NSEvent) {
    setHovered(false)
    setHoveredInteractionTarget(nil)
  }

  override func mouseMoved(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    setHovered(bounds.contains(point))
    setHoveredInteractionTarget(bounds.contains(point) ? interactionTarget(at: point) : nil)
  }

  override func mouseDown(with event: NSEvent) {
    guard isLayoutVisible, event.type == .leftMouseDown else {
      super.mouseDown(with: event)
      return
    }
    window?.makeFirstResponder(self)
    let point = convert(event.locationInWindow, from: nil)
    let target = interactionTarget(at: point)
    // A click can be the first pointer event delivered after a row moves under
    // a stationary cursor. Resolve and present the semantic target directly
    // from that event instead of waiting for a preceding mouseMoved callback.
    setHovered(bounds.contains(point))
    setHoveredInteractionTarget(bounds.contains(point) ? target : nil)
    mouseDownPoint = point
    capturedInteractionTarget = target
    setPressedInteractionTarget(capturedInteractionTarget)
  }

  override func mouseDragged(with event: NSEvent) {
    guard let mouseDownPoint else { return }
    let point = convert(event.locationInWindow, from: nil)
    if hypot(point.x - mouseDownPoint.x, point.y - mouseDownPoint.y) > 3 {
      setPressedInteractionTarget(nil)
    }
  }

  override func mouseUp(with event: NSEvent) {
    defer {
      mouseDownPoint = nil
      capturedInteractionTarget = nil
      setPressedInteractionTarget(nil)
      recomputePointerLocation()
    }
    let point = convert(event.locationInWindow, from: nil)
    guard let capturedInteractionTarget,
          pressedInteractionTarget == capturedInteractionTarget,
          isLayoutVisible,
          bounds.contains(point),
          interactionTarget(at: point) == capturedInteractionTarget
    else { return }

    switch capturedInteractionTarget {
    case .primary:
      primaryAction?()
      if event.clickCount >= 2 {
        doubleClickAction?()
      }
    case .accessory:
      performAccessoryAction(capturedInteractionTarget)
    }
  }

  override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
    true
  }

  override var acceptsFirstResponder: Bool {
    primaryAction != nil
  }

  override func accessibilityPerformPress() -> Bool {
    guard isLayoutVisible, let primaryAction else { return false }
    primaryAction()
    return true
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 36 || event.keyCode == 49 {
      primaryAction?()
      return
    }
    super.keyDown(with: event)
  }

  override func setLayoutVisibility(_ isVisible: Bool) {
    super.setLayoutVisibility(isVisible)
    if !isVisible {
      cancelPointerInteraction()
    } else {
      recomputePointerLocation()
    }
  }

  override func recomputePointerLocation() {
    guard isLayoutVisible,
          let window,
          window.isKeyWindow
    else {
      setHovered(false)
      setHoveredInteractionTarget(nil)
      return
    }
    let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
    let containsPointer = bounds.contains(point)
    setHovered(containsPointer)
    setHoveredInteractionTarget(containsPointer ? interactionTarget(at: point) : nil)
  }

  func interactionTarget(at _: NSPoint) -> InteractionTarget {
    .primary
  }

  func performAccessoryAction(_: InteractionTarget) {}
  func hoverDidChange() {}
  func pressDidChange() {}
  func interactionPresentationDidChange() {}

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard isLayoutVisible, super.hitTest(point) != nil else { return nil }
    // The row owns one deterministic pointer state machine. Visual hosting
    // leaves and accessory symbols never become competing event owners.
    return self
  }

  private func cancelPointerInteraction() {
    mouseDownPoint = nil
    capturedInteractionTarget = nil
    setPressedInteractionTarget(nil)
    setHoveredInteractionTarget(nil)
    setHovered(false)
  }

  private func setHovered(_ hovered: Bool) {
    guard isHovered != hovered else { return }
    isHovered = hovered
    hoverDidChange()
  }

  private func setHoveredInteractionTarget(_ target: InteractionTarget?) {
    guard hoveredInteractionTarget != target else { return }
    hoveredInteractionTarget = target
    interactionPresentationDidChange()
  }

  private func setPressedInteractionTarget(_ target: InteractionTarget?) {
    guard pressedInteractionTarget != target else { return }
    pressedInteractionTarget = target
    pressDidChange()
    interactionPresentationDidChange()
  }
}

@MainActor
private final class SidebarNativeNavigationRowView: SidebarNativeInteractiveContentView {
  private let backgroundLayer = CALayer()
  private let iconView = SidebarNativeHostedVisualView()
  private let titleField = SidebarNativeTextField()
  private let otherUnreadField = SidebarNativeTextField()
  private let prominentBadge = SidebarNativeUnreadBadgeView()
  private var avatarViews: [SidebarNativeIdentityView] = []
  private var configuration: SidebarNativeRowConfiguration.Navigation?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    SidebarNativeLayerUpdates.disableImplicitAnimations(on: backgroundLayer)
    layer?.addSublayer(backgroundLayer)
    addSubview(iconView)
    addSubview(titleField)
    addSubview(otherUnreadField)
    addSubview(prominentBadge)
    titleField.font = .systemFont(ofSize: 13)
    otherUnreadField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    otherUnreadField.textColor = .tertiaryLabelColor
    otherUnreadField.alignment = .right
    setAccessibilityRole(.button)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(_ configuration: SidebarNativeRowConfiguration.Navigation) {
    self.configuration = configuration
    primaryAction = configuration.action
    doubleClickAction = nil
    titleField.stringValue = configuration.title
    titleField.textColor = configuration.titleDimmed ? .secondaryLabelColor : .labelColor
    otherUnreadField.stringValue = configuration.otherUnreadCount > 0
      ? String(configuration.otherUnreadCount)
      : ""
    prominentBadge.configure(
      unreadCount: configuration.prominentUnreadCount,
      hasUnreadMark: false,
      prominent: true,
      style: .numbered,
      animatesChanges: allowsAnimations
    )
    prominentBadge.setPlacementVisible(true, animated: allowsAnimations)
    iconView.configure {
      SidebarActionRowIcon(
        systemImage: configuration.systemImage,
        size: configuration.size,
        weight: configuration.iconStyle == .newThread ? .regular : .medium
      )
    }
    toolTip = configuration.title == "New thread" ? "New Thread" : configuration.title
    configureAvatars(configuration.avatars)
    setAccessibilityLabel(configuration.title)
    setAccessibilityValue(configuration.accessibilityValue)
    setAccessibilitySelected(interactionPresentation.selected)
    updateBackground()
    needsLayout = true
    recomputePointerLocation()
  }

  override func layout() {
    super.layout()
    guard let configuration else { return }
    let painted = bounds.insetBy(dx: 8, dy: SidebarCollectionRow.itemVisualEdgeInset)
    backgroundLayer.frame = painted
    backgroundLayer.cornerRadius = Theme.sidebarItemRadius

    let iconSize = configuration.size.iconSize
    var leading = painted.minX + Theme.sidebarItemInnerSpacing
    iconView.frame = CGRect(
      x: leading,
      y: painted.midY - iconSize / 2,
      width: iconSize,
      height: iconSize
    )
    leading = iconView.frame.maxX + 8
    var trailing = painted.maxX - Theme.sidebarItemOuterSpacing

    for view in avatarViews.reversed() {
      trailing -= 14
      view.frame = CGRect(x: trailing, y: painted.midY - 10, width: 20, height: 20)
    }
    if !avatarViews.isEmpty {
      trailing -= 6
    }

    if configuration.prominentUnreadCount > 0 {
      let width = prominentBadge.fittingWidth
      prominentBadge.frame = CGRect(
        x: trailing - width,
        y: painted.midY - 8,
        width: width,
        height: 16
      )
      trailing = prominentBadge.frame.minX - 6
    }

    if configuration.otherUnreadCount > 0 {
      let width = ceil(otherUnreadField.intrinsicContentSize.width)
      otherUnreadField.frame = CGRect(
        x: trailing - width,
        y: painted.midY - 8,
        width: width,
        height: 16
      )
      trailing = otherUnreadField.frame.minX - 6
    }

    titleField.frame = CGRect(
      x: leading,
      y: painted.midY - 9,
      width: max(trailing - leading, 0),
      height: 18
    )
  }

  override func hoverDidChange() {
    updateBackground()
  }

  override func pressDidChange() {
    updateBackground()
  }

  override func interactionPresentationDidChange() {
    setAccessibilitySelected(interactionPresentation.selected)
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    configuration = nil
    primaryAction = nil
    iconView.prepareForReuse()
    prominentBadge.prepareForReuse()
    avatarViews.forEach {
      $0.prepareForReuse()
      $0.removeFromSuperview()
    }
    avatarViews.removeAll()
  }

  private func configureAvatars(_ avatars: [SidebarNativeRowConfiguration.Avatar]) {
    while avatarViews.count > avatars.count {
      avatarViews.removeLast().removeFromSuperview()
    }
    while avatarViews.count < avatars.count {
      let view = SidebarNativeIdentityView()
      addSubview(view)
      avatarViews.append(view)
    }
    for (view, avatar) in zip(avatarViews, avatars) {
      view.configure(user: avatar, size: 20)
    }
  }

  private func updateBackground() {
    guard configuration != nil else { return }
    SidebarNativeLayerUpdates.setBackgroundColor(
      SidebarNativeColors.rowBackground(
        selected: hasSelectedPresentation,
        hovered: hasHoverPresentation,
        appearance: effectiveAppearance
      ).cgColor,
      on: backgroundLayer
    )
  }
}

@MainActor
private final class SidebarNativeHeaderDisclosureButton: NSButton {
  var actionHandler: (() -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    isBordered = false
    title = ""
    imagePosition = .noImage
    focusRingType = .none
    target = self
    action = #selector(performDisclosure)
    setAccessibilityElement(false)
    setAccessibilityHidden(true)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
    true
  }

  @objc private func performDisclosure() {
    actionHandler?()
  }
}

@MainActor
private final class SidebarNativeHeaderRowView: SidebarNativeInteractiveContentView {
  private let titleField = SidebarNativeTextField()
  private let chevronView = SidebarNativeHostedVisualView()
  private let cleanupView = SidebarNativeHostedVisualView()
  private let disclosureButton = SidebarNativeHeaderDisclosureButton()
  private var configuration: SidebarNativeRowConfiguration.Header?
  private var displayedIsExpanded: Bool?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    addSubview(disclosureButton)
    addSubview(titleField)
    addSubview(cleanupView)
    addSubview(chevronView)
    titleField.font = .systemFont(ofSize: 11, weight: .medium)
    titleField.textColor = .secondaryLabelColor
    cleanupView.configure { SidebarSectionCleanupIcon() }
    cleanupView.toolTip = "Open Chats Cleanup"
    setAccessibilityRole(.group)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(_ configuration: SidebarNativeRowConfiguration.Header) {
    self.configuration = configuration
    displayedIsExpanded = configuration.isExpanded
    titleField.stringValue = configuration.title
    cleanupView.configure { SidebarSectionCleanupIcon() }
    let isSection = configuration.style == .section
    if isSection {
      let toggle: () -> Void = { [weak self] in
        self?.performDisclosureToggle()
      }
      primaryAction = toggle
      disclosureButton.actionHandler = toggle
    } else {
      primaryAction = nil
      disclosureButton.actionHandler = nil
    }
    disclosureButton.isEnabled = isSection
    doubleClickAction = nil
    chevronView.isHidden = !isSection
    cleanupView.isHidden = configuration.onCleanUp == nil
      || configuration.onCloseAll == nil
    configureChevron()
    updateControlPresentation(animated: false)
    if isSection {
      setAccessibilityRole(.button)
    } else if #available(macOS 26, *) {
      setAccessibilityRole(.headingRole)
    } else {
      setAccessibilityRole(.group)
    }
    updateDisclosureAccessibility()
    if configuration.onCleanUp != nil, configuration.onCloseAll != nil {
      setAccessibilityCustomActions([
        NSAccessibilityCustomAction(name: "Open Chats Cleanup") { [weak self] in
          self?.showCleanupMenu()
          return self != nil
        },
      ])
    } else {
      setAccessibilityCustomActions([])
    }
    needsLayout = true
    recomputePointerLocation()
  }

  override func layout() {
    super.layout()
    guard let configuration else { return }
    let top = configuration.topSpacing
    switch configuration.style {
    case .archive:
      titleField.frame = CGRect(
        x: Theme.sidebarItemOuterSpacing,
        y: max(bounds.height - 20, 0),
        width: max(bounds.width - Theme.sidebarItemOuterSpacing * 2, 0),
        height: 16
      )
    case .timeline:
      let contentHeight = max(bounds.height - top, 0)
      let titleHeight = min(16, contentHeight)
      titleField.frame = CGRect(
        x: Theme.sidebarItemInnerSpacing + 8,
        y: top + (contentHeight - titleHeight) / 2,
        width: max(bounds.width - Theme.sidebarItemInnerSpacing - 15, 0),
        height: titleHeight
      )
    case .section:
      let contentHeight = max(bounds.height - top, 0)
      let centerY = top + contentHeight / 2
      let controlSize = SidebarSectionHeaderMetrics.controlSize
      let controlsY = centerY - controlSize / 2
      let titleHeight = min(16, contentHeight)
      chevronView.frame = CGRect(
        x: bounds.width - SidebarSectionHeaderMetrics.trailingInset - controlSize,
        y: controlsY,
        width: controlSize,
        height: controlSize
      )
      cleanupView.frame = CGRect(
        x: chevronView.frame.minX - controlSize,
        y: controlsY,
        width: controlSize,
        height: controlSize
      )
      let titleTrailing = cleanupView.isHidden
        ? chevronView.frame.minX
        : cleanupView.frame.minX
      titleField.frame = CGRect(
        x: SidebarSectionHeaderMetrics.leadingInset,
        y: centerY - titleHeight / 2,
        width: max(titleTrailing - SidebarSectionHeaderMetrics.leadingInset, 0),
        height: titleHeight
      )
      disclosureButton.frame = bounds
    }
  }

  override func hoverDidChange() {
    updateControlPresentation(animated: true)
  }

  override func keyDown(with event: NSEvent) {
    guard let configuration, configuration.style == .section else {
      super.keyDown(with: event)
      return
    }
    if event.keyCode == 123, displayedIsExpanded == true {
      performDisclosureToggle()
      return
    }
    if event.keyCode == 124, displayedIsExpanded == false {
      performDisclosureToggle()
      return
    }
    super.keyDown(with: event)
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    configuration = nil
    displayedIsExpanded = nil
    primaryAction = nil
    disclosureButton.actionHandler = nil
    disclosureButton.isEnabled = false
    chevronView.prepareForReuse()
    cleanupView.prepareForReuse()
  }

  override func interactionTarget(at point: NSPoint) -> InteractionTarget {
    if cleanupAcceptsInteraction, cleanupView.frame.contains(point) {
      return .accessory(0)
    }
    return .primary
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard isLayoutVisible, super.hitTest(point) != nil else { return nil }
    guard let configuration, configuration.style == .section else { return self }
    if cleanupAcceptsInteraction, cleanupView.frame.contains(point) {
      return self
    }
    // A real NSButton owns the physical disclosure click. The surrounding
    // row keeps hover and accessibility semantics, while AppKit's control
    // tracking guarantees a mouse-up remains actionable after collection
    // reuse or a stationary-pointer collapse/expand cycle.
    return disclosureButton
  }

  private var cleanupAcceptsInteraction: Bool {
    cleanupView.isHidden == false && cleanupView.alphaValue > 0.01
  }

  override func performAccessoryAction(_ target: InteractionTarget) {
    guard target == .accessory(0) else { return }
    showCleanupMenu()
  }

  private func updateControlPresentation(animated: Bool) {
    guard let configuration, configuration.style == .section else { return }
    let isExpanded = displayedIsExpanded == true
    let chevronOpacity: CGFloat = isExpanded && !isHovered ? 0 : 1
    let cleanupOpacity: CGFloat = isHovered ? 1 : 0
    guard animated,
          allowsAnimations,
          !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    else {
      chevronView.alphaValue = chevronOpacity
      cleanupView.alphaValue = cleanupOpacity
      return
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.1
      chevronView.animator().alphaValue = chevronOpacity
      cleanupView.animator().alphaValue = cleanupOpacity
    }
  }

  private func performDisclosureToggle() {
    guard let configuration,
          configuration.style == .section,
          let displayedIsExpanded
    else { return }
    self.displayedIsExpanded = !displayedIsExpanded
    configureChevron()
    updateControlPresentation(animated: false)
    updateDisclosureAccessibility()
    configuration.onToggle?()
  }

  private func configureChevron() {
    chevronView.configure {
      SidebarSectionChevronIcon(
        isExpanded: displayedIsExpanded == true,
        animates: allowsAnimations
          && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
      )
    }
  }

  private func updateDisclosureAccessibility() {
    guard let configuration else { return }
    guard let displayedIsExpanded else {
      setAccessibilityLabel(configuration.title)
      setAccessibilityValue(nil)
      return
    }
    setAccessibilityLabel(displayedIsExpanded
      ? "Collapse \(configuration.title)"
      : "Expand \(configuration.title)")
    setAccessibilityValue(displayedIsExpanded ? "Expanded" : "Collapsed")
  }

  private func showCleanupMenu() {
    guard let configuration,
          let onCleanUp = configuration.onCleanUp,
          let onCloseAll = configuration.onCloseAll
    else { return }
    let menu = NSMenu(title: "Open Chats Cleanup")
    menu.addItem(SidebarNativeMenuItem(
      title: "Cleanup…",
      systemImage: "eraser.line.dashed",
      action: onCleanUp
    ))
    menu.addItem(SidebarNativeMenuItem(
      title: "Close All",
      systemImage: "xmark.circle",
      action: onCloseAll
    ))
    menu.popUp(
      positioning: nil,
      at: NSPoint(x: cleanupView.frame.minX, y: cleanupView.frame.maxY),
      in: self
    )
  }
}

@MainActor
private final class SidebarNativePinDropGuideRowView: SidebarNativeContentView {
  private let hostedView = SidebarNativeHostedVisualView()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    addSubview(hostedView)
    setAccessibilityLabel("Move here to pin")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(_ configuration: SidebarNativeRowConfiguration.PinDropGuide) {
    hostedView.configure {
      SidebarCollectionPinDropGuideView(
        dimsInstruction: configuration.dimsInstruction
      )
    }
    needsLayout = true
  }

  override func layout() {
    super.layout()
    hostedView.frame = bounds
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    hostedView.prepareForReuse()
  }
}

@MainActor
private final class SidebarNativeEmptyStateRowView: SidebarNativeContentView {
  private let iconView = SidebarNativeImageView()
  private let titleField = SidebarNativeTextField()
  private let actionButton = SidebarNativeTextButton()
  private var configuration: SidebarNativeRowConfiguration.EmptyState?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    addSubview(iconView)
    addSubview(titleField)
    addSubview(actionButton)
    titleField.font = .systemFont(ofSize: 12)
    titleField.textColor = .tertiaryLabelColor
    titleField.alignment = .center
    iconView.contentTintColor = .tertiaryLabelColor
    actionButton.actionHandler = { [weak self] in self?.configuration?.action?() }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(_ configuration: SidebarNativeRowConfiguration.EmptyState) {
    self.configuration = configuration
    iconView.image = NSImage(
      systemSymbolName: configuration.systemImage,
      accessibilityDescription: nil
    )?.withSymbolConfiguration(.init(pointSize: 16, weight: .regular))
    titleField.stringValue = configuration.title
    actionButton.title = configuration.actionTitle ?? ""
    actionButton.isHidden = configuration.actionTitle == nil || configuration.action == nil
    setAccessibilityLabel(configuration.title)
    needsLayout = true
  }

  override func layout() {
    super.layout()
    let totalHeight: CGFloat = actionButton.isHidden ? 41 : 73
    var y = max((bounds.height - totalHeight) / 2, 0)
    iconView.frame = CGRect(x: bounds.midX - 10, y: y, width: 20, height: 20)
    y += 27
    titleField.frame = CGRect(x: 16, y: y, width: max(bounds.width - 32, 0), height: 16)
    if !actionButton.isHidden {
      y += 24
      let width = min(max(actionButton.intrinsicContentSize.width + 20, 70), bounds.width - 32)
      actionButton.frame = CGRect(x: bounds.midX - width / 2, y: y, width: width, height: 24)
    }
  }
}

@MainActor
private final class SidebarNativeTextButton: NSButton {
  var actionHandler: (() -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    bezelStyle = .roundRect
    controlSize = .small
    font = .systemFont(ofSize: 12)
    target = self
    action = #selector(performAction)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  @objc private func performAction() {
    actionHandler?()
  }
}

@MainActor
private final class SidebarNativeTextField: NSTextField {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    isEditable = false
    isSelectable = false
    isBordered = false
    drawsBackground = false
    lineBreakMode = .byTruncatingTail
    maximumNumberOfLines = 1
    cell?.usesSingleLineMode = true
    setAccessibilityElement(false)
    setAccessibilityHidden(true)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func hitTest(_: NSPoint) -> NSView? {
    nil
  }
}

@MainActor
private final class SidebarNativeImageView: NSImageView {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityElement(false)
    setAccessibilityHidden(true)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func hitTest(_: NSPoint) -> NSView? {
    nil
  }
}

@MainActor
private final class SidebarNativeMenuItem: NSMenuItem {
  private let actionHandler: () -> Void

  init(title: String, systemImage: String, action: @escaping () -> Void) {
    actionHandler = action
    super.init(title: title, action: #selector(performAction), keyEquivalent: "")
    target = self
    image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
  }

  @available(*, unavailable)
  required init(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  @objc private func performAction() {
    actionHandler()
  }
}

private enum SidebarNativeColors {
  static func rowBackground(
    selected: Bool,
    hovered: Bool,
    appearance: NSAppearance
  ) -> NSColor {
    let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    if selected {
      return isDark
        ? NSColor.white.withAlphaComponent(0.10)
        : NSColor.black.withAlphaComponent(0.07)
    }
    if hovered {
      return isDark
        ? NSColor.white.withAlphaComponent(0.06)
        : NSColor.black.withAlphaComponent(0.05)
    }
    return .clear
  }
}

private enum SidebarNativeLayerUpdates {
  private static let disabledActions: [String: CAAction] = [
    "backgroundColor": NSNull(),
    "bounds": NSNull(),
    "cornerRadius": NSNull(),
    "opacity": NSNull(),
    "path": NSNull(),
    "position": NSNull(),
    "transform": NSNull(),
  ]

  static func disableImplicitAnimations(on layer: CALayer?) {
    layer?.actions = disabledActions
  }

  static func setBackgroundColor(_ color: CGColor?, on layer: CALayer?) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer?.backgroundColor = color
    CATransaction.commit()
  }
}

@MainActor
private final class SidebarNativeFolderRowView: SidebarNativeInteractiveContentView {
  private let backgroundLayer = CALayer()
  private let disclosureView = SidebarNativeHostedVisualView()
  private let folderImageView = NSImageView()
  private let titleField = SidebarNativeTextField()
  private let detailField = SidebarNativeTextField()
  private let closeView = SidebarNativeCloseAccessoryView()
  private var configuration: SidebarNativeRowConfiguration.Folder?
  private var displayedExpanded = true

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    SidebarNativeLayerUpdates.disableImplicitAnimations(on: backgroundLayer)
    layer?.addSublayer(backgroundLayer)
    addSubview(disclosureView)
    addSubview(folderImageView)
    addSubview(titleField)
    addSubview(detailField)
    addSubview(closeView)
    folderImageView.imageScaling = .scaleProportionallyDown
    titleField.font = .systemFont(ofSize: 13)
    detailField.font = .systemFont(ofSize: 11)
    detailField.textColor = .secondaryLabelColor
    closeView.configureIcon()
    setAccessibilityRole(.button)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(_ configuration: SidebarNativeRowConfiguration.Folder) {
    self.configuration = configuration
    displayedExpanded = configuration.disclosureExpanded
    primaryAction = configuration.actions.toggleDisclosure
    closeView.configure(action: configuration.actions.close)
    titleField.stringValue = configuration.presentation.title
    titleField.textColor = configuration.titleDimmed ? .secondaryLabelColor : .labelColor
    detailField.stringValue = folderDetail(configuration.presentation)
    configureFolderIcon()
    configureDisclosureVisual()
    updateControlPresentation(animated: false)
    updateBackground()
    updateAccessibility()
    needsLayout = true
    recomputePointerLocation()
  }

  override func layout() {
    super.layout()
    guard let configuration else { return }
    let painted = bounds.insetBy(dx: 8, dy: SidebarCollectionRow.itemVisualEdgeInset)
    backgroundLayer.frame = painted
    backgroundLayer.cornerRadius = Theme.sidebarItemRadius

    let disclosureFrame = CGRect(
      x: painted.minX + max((Theme.sidebarItemInnerSpacing - 24) / 2, 0),
      y: painted.minY,
      width: SidebarNativeFolderRowMetrics.disclosureWidth,
      height: painted.height
    )
    disclosureView.frame = disclosureFrame
    var leading = disclosureFrame.maxX + 1
    let iconSize = configuration.size.iconSize
    folderImageView.frame = CGRect(
      x: leading,
      y: painted.midY - iconSize / 2,
      width: iconSize,
      height: iconSize
    )
    leading = folderImageView.frame.maxX + 8

    closeView.frame = closeHitRect(in: painted)
    let trailing = closeView.alphaValue > 0.01
      ? closeView.frame.minX - 8
      : painted.maxX - Theme.sidebarItemInnerSpacing
    if configuration.size == .compact {
      titleField.frame = CGRect(
        x: leading,
        y: painted.midY - 9,
        width: max(trailing - leading, 0),
        height: 18
      )
      detailField.frame = .zero
      detailField.isHidden = true
    } else {
      titleField.frame = CGRect(
        x: leading,
        y: painted.midY - 15,
        width: max(trailing - leading, 0),
        height: 16
      )
      detailField.frame = CGRect(
        x: leading,
        y: painted.midY + 1,
        width: max(trailing - leading, 0),
        height: 14
      )
      detailField.isHidden = false
    }
  }

  override func hoverDidChange() {
    updateControlPresentation(animated: true)
    updateBackground()
  }

  override func pressDidChange() {
    updateBackground()
  }

  override func keyDown(with event: NSEvent) {
    guard let configuration else {
      super.keyDown(with: event)
      return
    }
    if event.keyCode == 123, displayedExpanded {
      performDisclosureToggle()
      return
    }
    if event.keyCode == 124, !displayedExpanded {
      performDisclosureToggle()
      return
    }
    if event.keyCode == 51 {
      configuration.actions.close()
      return
    }
    super.keyDown(with: event)
  }

  override func menu(for _: NSEvent) -> NSMenu? {
    guard let configuration else { return nil }
    let menu = NSMenu()
    menu.addItem(SidebarNativeMenuItem(
      title: "Ungroup (Keep Chats)",
      systemImage: "folder.badge.minus",
      action: configuration.actions.ungroup
    ))
    menu.addItem(.separator())
    menu.addItem(SidebarNativeMenuItem(
      title: "Close Folder and Chats",
      systemImage: "xmark",
      action: configuration.actions.close
    ))
    return menu
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    configuration = nil
    primaryAction = nil
    closeView.prepareForReuse()
    disclosureView.prepareForReuse()
    folderImageView.image = nil
    setAccessibilityCustomActions([])
  }

  override func interactionTarget(at point: NSPoint) -> InteractionTarget {
    let painted = bounds.insetBy(dx: 8, dy: SidebarCollectionRow.itemVisualEdgeInset)
    if closeHitRect(in: painted).contains(point) { return .accessory(0) }
    if disclosureView.frame.contains(point) { return .accessory(1) }
    return .primary
  }

  override func blocksReorder(at point: NSPoint) -> Bool {
    interactionTarget(at: point) != .primary
  }

  override func performAccessoryAction(_ target: InteractionTarget) {
    guard let configuration else { return }
    switch target {
    case .accessory(0): configuration.actions.close()
    case .accessory(1): performDisclosureToggle()
    default: break
    }
  }

  override func interactionPresentationDidChange() {
    closeView.configureInteraction(
      hovered: hoveredInteractionTarget == .accessory(0),
      pressed: pressedInteractionTarget == .accessory(0)
    )
    updateAccessibility()
  }

  private func performDisclosureToggle() {
    guard let configuration else { return }
    displayedExpanded.toggle()
    configureFolderIcon()
    configureDisclosureVisual()
    updateAccessibility()
    configuration.actions.toggleDisclosure()
  }

  private func configureFolderIcon() {
    folderImageView.image = NSImage(
      systemSymbolName: displayedExpanded ? "folder.fill" : "folder",
      accessibilityDescription: nil
    )
    folderImageView.contentTintColor = .secondaryLabelColor
  }

  private func configureDisclosureVisual() {
    guard let configuration else { return }
    disclosureView.toolTip = displayedExpanded ? "Collapse folder" : "Expand folder"
    disclosureView.configure {
      SidebarChatDisclosureIcon(
        isExpanded: displayedExpanded,
        rowHeight: configuration.size.rowHeight,
        animates: allowsAnimations
          && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
      )
    }
  }

  private func updateControlPresentation(animated: Bool) {
    guard let configuration else { return }
    let visible = hasHoverPresentation
    let alpha: CGFloat = visible ? 1 : 0
    if animated, allowsAnimations,
       !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.14
        closeView.animator().alphaValue = alpha
      }
    } else {
      closeView.alphaValue = alpha
    }
    closeView.setAccessibilityHidden(false)
    needsLayout = true
  }

  private func updateBackground() {
    guard let configuration else { return }
    SidebarNativeLayerUpdates.setBackgroundColor(
      SidebarNativeColors.rowBackground(
        selected: hasSelectedPresentation,
        hovered: hasHoverPresentation,
        appearance: effectiveAppearance
      ).cgColor,
      on: backgroundLayer
    )
  }

  private func updateAccessibility() {
    guard let configuration else { return }
    setAccessibilityLabel(configuration.presentation.title)
    setAccessibilityValue(folderDetail(configuration.presentation))
    setAccessibilityCustomActions([
      NSAccessibilityCustomAction(
        name: displayedExpanded ? "Collapse folder" : "Expand folder"
      ) { [weak self] in
        self?.performDisclosureToggle()
        return self != nil
      },
      NSAccessibilityCustomAction(name: "Ungroup and keep chats") {
        configuration.actions.ungroup()
        return true
      },
      NSAccessibilityCustomAction(name: "Close folder and chats") {
        configuration.actions.close()
        return true
      },
    ])
  }

  private func folderDetail(
    _ presentation: SidebarNativeRowConfiguration.FolderPresentation
  ) -> String {
    let chats = "\(presentation.childCount) chat\(presentation.childCount == 1 ? "" : "s")"
    guard presentation.unreadCount > 0 else { return chats }
    return "\(chats), \(presentation.unreadCount) unread"
  }

  private func closeHitRect(in painted: CGRect) -> CGRect {
    let size = SidebarNativeFolderRowMetrics.accessoryHitSize
    return CGRect(
      x: painted.maxX - Theme.sidebarItemInnerSpacing - size,
      y: painted.midY - size / 2,
      width: size,
      height: size
    )
  }
}

@MainActor
private final class SidebarNativeChatRowView: SidebarNativeInteractiveContentView {
  private let backgroundLayer = CALayer()
  private let leadingUnreadBadge = SidebarNativeUnreadBadgeView()
  private let identityView = SidebarNativeIdentityView()
  private let titleField = SidebarNativeTextField()
  private let previewView = SidebarNativeComposeActivityView()
  private let titleActivityView = SidebarNativeComposeActivityView()
  private let trailingUnreadBadge = SidebarNativeUnreadBadgeView()
  private let closeView = SidebarNativeCloseAccessoryView()
  private let disclosureView = SidebarNativeHostedVisualView()
  private var configuration: SidebarNativeRowConfiguration.Chat?
  private var displayedDisclosureExpanded: Bool?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    SidebarNativeLayerUpdates.disableImplicitAnimations(on: backgroundLayer)
    layer?.addSublayer(backgroundLayer)
    addSubview(leadingUnreadBadge)
    addSubview(identityView)
    addSubview(titleField)
    addSubview(previewView)
    addSubview(titleActivityView)
    addSubview(trailingUnreadBadge)
    addSubview(closeView)
    addSubview(disclosureView)

    titleField.font = .systemFont(ofSize: 13)
    closeView.configureIcon()
    titleActivityView.visibilityChanged = { [weak self] in
      self?.needsLayout = true
    }
    setAccessibilityRole(.button)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(_ configuration: SidebarNativeRowConfiguration.Chat) {
    self.configuration = configuration
    displayedDisclosureExpanded = configuration.disclosureExpanded
    primaryAction = configuration.actions.open
    doubleClickAction = { [weak self] in
      guard let self, let configuration = self.configuration else { return }
      if configuration.isTemporary {
        configuration.actions.persist()
      }
      if configuration.presentation.parentChatID != nil {
        configuration.actions.rename()
      }
    }

    let presentation = configuration.presentation
    closeView.configure(action: configuration.actions.close)
    titleField.stringValue = presentation.title
    let titleFont = NSFont.systemFont(ofSize: 13)
    titleField.font = configuration.isTemporary
      ? NSFontManager.shared.convert(titleFont, toHaveTrait: .italicFontMask)
      : titleFont
    titleField.textColor = configuration.titleDimmed ? .secondaryLabelColor : .labelColor

    identityView.isHidden = !configuration.showsIcon
    if configuration.showsIcon {
      identityView.configure(
        identity: presentation.identity,
        size: configuration.size.iconSize,
        hasBackgroundShape: configuration.size != .compact
      )
    } else {
      identityView.prepareForReuse()
    }

    previewView.configure(
      peer: presentation.peerID,
      preview: presentation.preview,
      showsText: true,
      animatesChanges: allowsAnimations
    )
    titleActivityView.configure(
      peer: presentation.peerID,
      preview: "",
      showsText: false,
      animatesChanges: allowsAnimations
    )

    let showsPreview = configuration.size != .compact
    let titleHasNumberedUnread = configuration.unreadBadgeStyle == .numbered
      && presentation.unread
      && !showsPreview
    let previewHasNumberedUnread = configuration.unreadBadgeStyle == .numbered
      && presentation.unread
      && showsPreview
    trailingUnreadBadge.configure(
      unreadCount: presentation.unread ? presentation.unreadCount : 0,
      hasUnreadMark: presentation.unread && presentation.unreadMark,
      prominent: presentation.prominentUnreadDot,
      style: configuration.unreadBadgeStyle,
      animatesChanges: allowsAnimations
    )
    trailingUnreadBadge.setPlacementVisible(
      titleHasNumberedUnread || previewHasNumberedUnread,
      animated: allowsAnimations
    )
    leadingUnreadBadge.configure(
      unreadCount: presentation.unread ? presentation.unreadCount : 0,
      hasUnreadMark: presentation.unread && presentation.unreadMark,
      prominent: presentation.prominentUnreadDot,
      style: .dot,
      animatesChanges: allowsAnimations
    )
    leadingUnreadBadge.setPlacementVisible(
      configuration.unreadBadgeStyle == .dot,
      animated: allowsAnimations
    )

    closeView.toolTip = "Close"
    configureDisclosureVisual()
    updateControlPresentation(animated: false)
    updateBackground()
    updateAccessibility()
    needsLayout = true
    recomputePointerLocation()
  }

  override func layout() {
    super.layout()
    guard let configuration else { return }
    let presentation = configuration.presentation
    let painted = bounds.insetBy(dx: 8, dy: SidebarCollectionRow.itemVisualEdgeInset)
    backgroundLayer.frame = painted
    backgroundLayer.cornerRadius = Theme.sidebarItemRadius

    let indentation = CGFloat(min(max(configuration.indentationLevel, 0), 3)) * 16
    var leading = painted.minX + Theme.sidebarItemInnerSpacing + indentation
    if configuration.showsIcon {
      let iconSize = configuration.size.iconSize
      identityView.frame = CGRect(
        x: leading,
        y: painted.midY - iconSize / 2,
        width: iconSize,
        height: iconSize
      )
      leading = identityView.frame.maxX + 8
    }

    if configuration.unreadBadgeStyle == .dot {
      leadingUnreadBadge.frame = CGRect(
        x: painted.minX + Theme.sidebarItemUnreadDotLeadingSpacing,
        y: painted.midY - Theme.sidebarItemUnreadDotSize / 2,
        width: Theme.sidebarItemUnreadDotSize,
        height: Theme.sidebarItemUnreadDotSize
      )
    }

    disclosureView.frame = disclosureHitRect(in: painted)

    var availableTrailing = painted.maxX - Theme.sidebarItemOuterSpacing
    closeView.frame = closeHitRect(in: painted)
    if configuration.showsCloseButton, closeView.alphaValue > 0.01 {
      availableTrailing = closeVisualLeading(in: painted)
        - SidebarNativeChatRowMetrics.closeTextSpacing
    }
    var trailing = availableTrailing

    let showsPreview = configuration.size != .compact
    let badgeBelongsToPreview = configuration.unreadBadgeStyle == .numbered
      && presentation.unread
      && showsPreview
    if trailingUnreadBadge.occupiesLayout, !badgeBelongsToPreview {
      let width = trailingUnreadBadge.fittingWidth
      trailingUnreadBadge.frame = CGRect(
        x: trailing - width,
        y: painted.midY - 8,
        width: width,
        height: 16
      )
      trailing = trailingUnreadBadge.frame.minX - 8
    }

    if !showsPreview, titleActivityView.isActivityVisible {
      titleActivityView.frame = CGRect(x: trailing - 16, y: painted.midY - 6, width: 16, height: 12)
      trailing = titleActivityView.frame.minX - 8
    } else {
      titleActivityView.frame = .zero
    }

    if showsPreview {
      let lineHeight: CGFloat = 13
      let blockHeight = lineHeight * 2 + 2
      let top = painted.midY - blockHeight / 2
      titleField.frame = CGRect(
        x: leading,
        y: top,
        width: max(trailing - leading, 0),
        height: lineHeight + 2
      )
      var previewTrailing = availableTrailing
      if badgeBelongsToPreview, trailingUnreadBadge.occupiesLayout {
        let width = trailingUnreadBadge.fittingWidth
        trailingUnreadBadge.frame = CGRect(
          x: previewTrailing - width,
          y: top + lineHeight + 1,
          width: width,
          height: 16
        )
        previewTrailing = trailingUnreadBadge.frame.minX - 5
      }
      previewView.frame = CGRect(
        x: leading,
        y: top + lineHeight + 2,
        width: max(previewTrailing - leading, 0),
        height: lineHeight
      )
      previewView.isHidden = false
    } else {
      titleField.frame = CGRect(
        x: leading,
        y: painted.midY - 9,
        width: max(trailing - leading, 0),
        height: 18
      )
      previewView.frame = .zero
      previewView.isHidden = true
    }
  }

  override func hoverDidChange() {
    updateControlPresentation(animated: true)
    updateBackground()
  }

  override func pressDidChange() {
    updateBackground()
  }

  override func keyDown(with event: NSEvent) {
    guard let configuration else {
      super.keyDown(with: event)
      return
    }
    if event.keyCode == 123, displayedDisclosureExpanded == true {
      performDisclosureToggle()
      return
    }
    if event.keyCode == 124, displayedDisclosureExpanded == false {
      performDisclosureToggle()
      return
    }
    if event.keyCode == 51, configuration.showsCloseButton {
      configuration.actions.close()
      return
    }
    super.keyDown(with: event)
  }

  override func menu(for _: NSEvent) -> NSMenu? {
    guard let configuration else { return nil }
    let presentation = configuration.presentation
    let actions = configuration.actions
    let menu = NSMenu()
    menu.addItem(SidebarNativeMenuItem(
      title: "Open in New Tab",
      systemImage: "plus.rectangle.on.rectangle",
      action: actions.openInNewTab
    ))
    menu.addItem(SidebarNativeMenuItem(
      title: "Open in New Window",
      systemImage: "macwindow",
      action: actions.openInNewWindow
    ))
    if presentation.parentChatID != nil {
      menu.addItem(SidebarNativeMenuItem(
        title: "Rename Thread…",
        systemImage: "pencil",
        action: actions.rename
      ))
    }
    menu.addItem(.separator())

    if configuration.showsCloseButton {
      menu.addItem(SidebarNativeMenuItem(
        title: "Close from Sidebar",
        systemImage: "xmark",
        action: actions.close
      ))
      menu.addItem(.separator())
    }

    if configuration.isTemporary {
      menu.addItem(SidebarNativeMenuItem(
        title: "Keep in Sidebar",
        systemImage: "sidebar.left",
        action: actions.persist
      ))
    } else {
      menu.addItem(SidebarNativeMenuItem(
        title: presentation.pinned ? "Unpin" : "Pin",
        systemImage: presentation.pinned ? "pin.slash.fill" : "pin.fill",
        action: actions.togglePin
      ))
      menu.addItem(SidebarNativeMenuItem(
        title: presentation.unread ? "Mark Read" : "Mark Unread",
        systemImage: presentation.unread ? "checkmark.message.fill" : "envelope.badge.fill",
        action: actions.toggleReadUnread
      ))
      if let folderMenu = actions.folderMenu() {
        menu.addItem(.separator())
        let moveItem = NSMenuItem(title: "Move to Folder", action: nil, keyEquivalent: "")
        moveItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        let moveMenu = NSMenu(title: "Move to Folder")
        for destination in folderMenu.destinations {
          moveMenu.addItem(SidebarNativeMenuItem(
            title: destination.title,
            systemImage: "folder",
            action: destination.move
          ))
        }
        if folderMenu.destinations.isEmpty {
          let empty = NSMenuItem(title: "No other folders", action: nil, keyEquivalent: "")
          empty.isEnabled = false
          moveMenu.addItem(empty)
        }
        menu.setSubmenu(moveMenu, for: moveItem)
        menu.addItem(moveItem)
        menu.addItem(SidebarNativeMenuItem(
          title: "New Folder with Chat",
          systemImage: "folder.badge.plus",
          action: folderMenu.create
        ))
        if let removeFromFolder = folderMenu.removeFromFolder {
          menu.addItem(SidebarNativeMenuItem(
            title: "Remove from Folder",
            systemImage: "folder.badge.minus",
            action: removeFromFolder
          ))
        }
      }
    }
    return menu
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    configuration = nil
    displayedDisclosureExpanded = nil
    primaryAction = nil
    doubleClickAction = nil
    identityView.prepareForReuse()
    previewView.prepareForReuse()
    titleActivityView.prepareForReuse()
    leadingUnreadBadge.prepareForReuse()
    trailingUnreadBadge.prepareForReuse()
    closeView.prepareForReuse()
    disclosureView.prepareForReuse()
    setAccessibilityCustomActions([])
  }

  override func interactionTarget(at point: NSPoint) -> InteractionTarget {
    guard let configuration else { return .primary }
    let painted = bounds.insetBy(dx: 8, dy: SidebarCollectionRow.itemVisualEdgeInset)
    if configuration.showsCloseButton, closeHitRect(in: painted).contains(point) {
      return .accessory(0)
    }
    if configuration.disclosureExpanded != nil,
       disclosureHitRect(in: painted).contains(point) {
      return .accessory(1)
    }
    return .primary
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard isLayoutVisible, super.hitTest(point) != nil else { return nil }
    guard let configuration else { return self }
    let painted = bounds.insetBy(dx: 8, dy: SidebarCollectionRow.itemVisualEdgeInset)
    if configuration.showsCloseButton, closeHitRect(in: painted).contains(point) {
      // AppKit may deliver this mouse-down without a preceding mouseMoved when
      // the prior row disappeared under a stationary pointer. Route directly
      // to the real control and reveal its non-animated hover presentation.
      closeView.alphaValue = 1
      closeView.setAccessibilityHidden(false)
      closeView.configureInteraction(hovered: true, pressed: false)
      return closeView
    }
    return self
  }

  override func blocksReorder(at point: NSPoint) -> Bool {
    guard let configuration else { return false }
    let painted = bounds.insetBy(dx: 8, dy: SidebarCollectionRow.itemVisualEdgeInset)
    if configuration.showsCloseButton, closeHitRect(in: painted).contains(point) {
      return true
    }
    return configuration.disclosureExpanded != nil
      && disclosureHitRect(in: painted).contains(point)
  }

  override func performAccessoryAction(_ target: InteractionTarget) {
    guard let configuration else { return }
    switch target {
    case .accessory(0):
      configuration.actions.close()
    case .accessory(1):
      performDisclosureToggle()
    default:
      break
    }
  }

  override func interactionPresentationDidChange() {
    closeView.configureInteraction(
      hovered: hoveredInteractionTarget == .accessory(0),
      pressed: pressedInteractionTarget == .accessory(0)
    )
    updateAccessibility()
  }

  private func updateControlPresentation(animated: Bool) {
    guard let configuration else { return }
    let hasHoverAppearance = hasHoverPresentation
    let disclosureVisible = displayedDisclosureExpanded.map {
      !$0 || hasHoverAppearance
    } ?? false
    disclosureView.isHidden = displayedDisclosureExpanded == nil
    let closeVisible = configuration.showsCloseButton && hasHoverAppearance
    closeView.isHidden = false
    closeView.isEnabled = configuration.showsCloseButton
    closeView.alphaValue = closeVisible ? 1 : 0
    // Hover controls only the visual treatment. Keep the semantic AppKit
    // button available to assistive technologies whenever this mode supports
    // closing, just like the row's keyboard Delete action.
    closeView.setAccessibilityHidden(!configuration.showsCloseButton)
    leadingUnreadBadge.setObscured(
      disclosureVisible,
      animated: animated && allowsAnimations
    )

    let disclosureOpacity: CGFloat = disclosureVisible ? 1 : 0
    if animated,
       allowsAnimations,
       !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.14
        disclosureView.animator().alphaValue = disclosureOpacity
      }
    } else {
      disclosureView.alphaValue = disclosureOpacity
    }
    needsLayout = true
    recomputePointerLocation()
  }

  private func closeHitRect(in painted: CGRect) -> CGRect {
    let hitSize = SidebarNativeChatRowMetrics.closeHitSize
    let visualPadding = (hitSize - SidebarNativeChatRowMetrics.closeVisualSize) / 2
    return CGRect(
      x: closeVisualLeading(in: painted) - visualPadding,
      y: painted.midY - hitSize / 2,
      width: hitSize,
      height: hitSize
    )
  }

  private func closeVisualLeading(in painted: CGRect) -> CGFloat {
    painted.maxX
      - Theme.sidebarItemOuterSpacing
      - SidebarNativeChatRowMetrics.closeVisualSize
  }

  private func disclosureHitRect(in painted: CGRect) -> CGRect {
    CGRect(
      x: painted.minX + (Theme.sidebarItemInnerSpacing - 24) / 2,
      y: painted.minY,
      width: 24,
      height: painted.height
    )
  }

  private func updateBackground() {
    guard let configuration else { return }
    SidebarNativeLayerUpdates.setBackgroundColor(
      SidebarNativeColors.rowBackground(
        selected: hasSelectedPresentation,
        hovered: hasHoverPresentation,
        appearance: effectiveAppearance
      ).cgColor,
      on: backgroundLayer
    )
  }

  private func updateAccessibility() {
    guard let configuration else { return }
    let presentation = configuration.presentation
    setAccessibilityLabel(presentation.title)
    let unreadValue: String? = if presentation.unreadCount == 1 {
      "1 unread message"
    } else if presentation.unreadCount > 1 {
      "\(presentation.unreadCount) unread messages"
    } else if presentation.unreadMark {
      "Marked unread"
    } else if presentation.unread {
      "Unread"
    } else {
      nil
    }
    setAccessibilityValue(unreadValue)
    setAccessibilitySelected(interactionPresentation.selected)

    var actions: [NSAccessibilityCustomAction] = []
    if configuration.showsCloseButton {
      actions.append(NSAccessibilityCustomAction(name: "Close from Sidebar") {
        configuration.actions.close()
        return true
      })
    }
    if let expanded = displayedDisclosureExpanded {
      actions.append(NSAccessibilityCustomAction(
        name: expanded ? "Collapse reply threads" : "Expand reply threads"
      ) { [weak self] in
        guard let self else { return false }
        self.performDisclosureToggle()
        return true
      })
    }
    if configuration.isTemporary {
      actions.append(NSAccessibilityCustomAction(name: "Keep in Sidebar") {
        configuration.actions.persist()
        return true
      })
    } else {
      actions.append(NSAccessibilityCustomAction(name: presentation.pinned ? "Unpin" : "Pin") {
        configuration.actions.togglePin()
        return true
      })
      actions.append(NSAccessibilityCustomAction(name: presentation.unread ? "Mark Read" : "Mark Unread") {
        configuration.actions.toggleReadUnread()
        return true
      })
    }
    setAccessibilityCustomActions(actions)
  }

  private func performDisclosureToggle() {
    guard let configuration, let displayedDisclosureExpanded else { return }
    self.displayedDisclosureExpanded = !displayedDisclosureExpanded
    configureDisclosureVisual()
    updateControlPresentation(animated: false)
    updateAccessibility()
    configuration.actions.toggleDisclosure()
  }

  private func configureDisclosureVisual() {
    guard let configuration else { return }
    disclosureView.toolTip = displayedDisclosureExpanded == true
      ? "Collapse reply threads"
      : "Expand reply threads"
    disclosureView.configure {
      SidebarChatDisclosureIcon(
        isExpanded: displayedDisclosureExpanded == true,
        rowHeight: configuration.size.rowHeight,
        animates: allowsAnimations
          && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
      )
    }
  }
}

@MainActor
@Observable
private final class SidebarNativeUnreadBadgeState {
  struct Value: Equatable {
    var unreadCount = 0
    var hasUnreadMark = false
    var prominent = false
    var style = UnreadBadgeStyle.dot
    var animatesChanges = false
  }

  var value = Value()
}

private struct SidebarNativeUnreadBadgeRoot: View {
  let state: SidebarNativeUnreadBadgeState

  var body: some View {
    let value = state.value
    UnreadBadge(
      unreadCount: value.unreadCount,
      hasUnreadMark: value.hasUnreadMark,
      prominent: value.prominent,
      style: value.style,
      dotSize: Theme.sidebarItemUnreadDotSize
    )
    .fixedSize()
    .transaction { transaction in
      if value.animatesChanges == false {
        transaction.animation = nil
        transaction.disablesAnimations = true
      }
    }
  }
}

@MainActor
private final class SidebarNativeUnreadBadgeView: NSView {
  private let state: SidebarNativeUnreadBadgeState
  private let hostedView: NSHostingView<SidebarNativeUnreadBadgeRoot>
  private var isVisible = false
  private var isNumbered = false
  private var count = 0
  private var placementVisible = false
  private var isObscured = false
  private var hasSetPlacement = false
  private var hasConfigured = false

  override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    let state = SidebarNativeUnreadBadgeState()
    self.state = state
    hostedView = NSHostingView(rootView: SidebarNativeUnreadBadgeRoot(state: state))
    super.init(frame: frameRect)
    hostedView.sizingOptions = []
    hostedView.wantsLayer = true
    hostedView.clipsToBounds = true
    addSubview(hostedView)
    setAccessibilityElement(false)
    setAccessibilityHidden(true)
    hostedView.setAccessibilityElement(false)
    hostedView.setAccessibilityHidden(true)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  var fittingWidth: CGFloat {
    guard isVisible else { return 0 }
    guard isNumbered else { return Theme.sidebarItemUnreadDotSize }
    let width = (String(count) as NSString).size(withAttributes: [
      .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold),
    ]).width
    return max(16, ceil(width) + 10)
  }

  var occupiesLayout: Bool {
    placementVisible && isVisible
  }

  func configure(
    unreadCount: Int,
    hasUnreadMark: Bool,
    prominent: Bool,
    style: UnreadBadgeStyle,
    animatesChanges: Bool = true
  ) {
    count = max(unreadCount, 0)
    isVisible = count > 0 || hasUnreadMark
    isNumbered = style == .numbered && count > 0
    state.value = SidebarNativeUnreadBadgeState.Value(
      unreadCount: count,
      hasUnreadMark: hasUnreadMark,
      prominent: prominent,
      style: style,
      animatesChanges: animatesChanges && hasConfigured
    )
    hasConfigured = true
    needsLayout = true
  }

  /// Placement is owned by AppKit (leading dot versus trailing count), while
  /// unread appearance/disappearance remains owned by the shared SwiftUI
  /// `UnreadBadge`. Keeping the host mounted lets its exact scale/opacity and
  /// color behavior run instead of being cancelled by `isHidden`.
  func setPlacementVisible(_ visible: Bool, animated: Bool) {
    guard placementVisible != visible || !hasSetPlacement else { return }
    placementVisible = visible
    updateHostedVisibility(animated: animated && hasSetPlacement, duration: 0.18)
    hasSetPlacement = true
  }

  func setObscured(_ obscured: Bool, animated: Bool) {
    guard isObscured != obscured else { return }
    isObscured = obscured
    updateHostedVisibility(animated: animated, duration: 0.14)
  }

  override func layout() {
    super.layout()
    hostedView.frame = bounds
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    isVisible = false
    isNumbered = false
    count = 0
    placementVisible = false
    isObscured = false
    hasSetPlacement = false
    hasConfigured = false
    hostedView.layer?.removeAllAnimations()
    hostedView.alphaValue = 0
    state.value = SidebarNativeUnreadBadgeState.Value()
  }

  override func hitTest(_: NSPoint) -> NSView? {
    nil
  }

  private func updateHostedVisibility(animated: Bool, duration: TimeInterval) {
    let alpha: CGFloat = placementVisible && !isObscured ? 1 : 0
    guard animated,
          !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    else {
      hostedView.alphaValue = alpha
      return
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = duration
      context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      hostedView.animator().alphaValue = alpha
    }
  }

}

@MainActor
private final class SidebarNativeCloseAccessoryView: NSButton {
  private let visualBackgroundLayer = CALayer()
  private let iconView = SidebarNativeHostedVisualView()
  private var actionHandler: (() -> Void)?
  private var isHovering = false
  private var isPressing = false

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    visualBackgroundLayer.cornerRadius = 5
    visualBackgroundLayer.cornerCurve = .continuous
    SidebarNativeLayerUpdates.disableImplicitAnimations(on: visualBackgroundLayer)
    layer?.addSublayer(visualBackgroundLayer)
    isBordered = false
    title = ""
    imagePosition = .noImage
    focusRingType = .none
    target = self
    action = #selector(performClose)
    // Keep AppKit's standard cancellable mouse-up activation. The collection
    // owner projects a successful click optimistically after the action fires;
    // removing a row on mouse-down makes drag-away cancellation impossible.
    addSubview(iconView)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    setAccessibilityLabel("Close")
    setAccessibilityHidden(true)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configureIcon() {
    iconView.configure { SidebarChatCloseIcon() }
  }

  func configure(action: @escaping () -> Void) {
    actionHandler = action
    isEnabled = true
  }

  func configureInteraction(hovered: Bool, pressed: Bool) {
    isHovering = hovered
    isPressing = pressed
    updateBackground()
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    actionHandler = nil
    isEnabled = false
    isHovering = false
    isPressing = false
    updateBackground()
  }

  override func mouseDown(with event: NSEvent) {
    isPressing = true
    updateBackground()
    defer {
      isPressing = false
      updateBackground()
    }
    super.mouseDown(with: event)
  }

  override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
    true
  }

  override func layout() {
    super.layout()
    let visualSize = CGSize(
      width: SidebarNativeChatRowMetrics.closeVisualSize,
      height: SidebarNativeChatRowMetrics.closeVisualSize
    )
    let visualFrame = CGRect(
      x: bounds.midX - visualSize.width / 2,
      y: bounds.midY - visualSize.height / 2,
      width: visualSize.width,
      height: visualSize.height
    )
    visualBackgroundLayer.frame = visualFrame
    iconView.frame = visualFrame
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateBackground()
  }

  private func updateBackground() {
    let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let alpha: CGFloat = isPressing ? (isDark ? 0.16 : 0.13) : (isHovering
      ? (isDark ? 0.10 : 0.08)
      : 0)
    SidebarNativeLayerUpdates.setBackgroundColor(
      (isDark ? NSColor.white : NSColor.black).withAlphaComponent(alpha).cgColor,
      on: visualBackgroundLayer
    )
  }

  @objc private func performClose() {
    let handler = actionHandler
    handler?()
  }
}

@MainActor
private final class SidebarNativeComposeActivityView: NSView {
  enum Mode {
    case text
    case indicator
  }

  var visibilityChanged: (() -> Void)?
  private let indicatorView = SidebarNativeComposeIndicatorView()
  private let label = SidebarNativeTextField()
  private var activityState: ComposeActionActivityState?
  private var preview = ""
  private var mode = Mode.text
  private var allowsAnimations = true
  private var lastPresentation: ComposeActionPresentation?
  private var hasAppliedPresentation = false
  private(set) var isActivityVisible = false

  override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    clipsToBounds = true
    addSubview(indicatorView)
    addSubview(label)
    label.font = .systemFont(ofSize: 11)
    label.textColor = .tertiaryLabelColor
    setAccessibilityElement(false)
    setAccessibilityHidden(true)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(
    peer: Peer,
    preview: String,
    showsText: Bool,
    animatesChanges: Bool
  ) {
    activityState = ComposeActions.shared.activityState(for: peer)
    self.preview = preview
    mode = showsText ? .text : .indicator
    allowsAnimations = animatesChanges
    lastPresentation = nil
    hasAppliedPresentation = false
    indicatorView.refreshColor()
    needsLayout = true
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    activityState = nil
    lastPresentation = nil
    hasAppliedPresentation = false
    preview = ""
    isActivityVisible = false
    indicatorView.configure(nil)
    label.stringValue = ""
  }

  override func layout() {
    super.layout()
    // Inline opts AppKit into Observation tracking on macOS 15. Reading the
    // per-peer leaf here invalidates only this reusable row when activity changes.
    let presentation = activityState?.presentation
    if !hasAppliedPresentation || presentation != lastPresentation {
      apply(presentation)
    }
    let indicatorWidth: CGFloat = isActivityVisible ? 16 : 0
    indicatorView.frame = CGRect(x: 0, y: max((bounds.height - 12) / 2, 0), width: indicatorWidth, height: 12)
    label.frame = CGRect(
      x: indicatorWidth > 0 ? indicatorWidth + 5 : 0,
      y: 0,
      width: max(bounds.width - indicatorWidth - (indicatorWidth > 0 ? 5 : 0), 0),
      height: bounds.height
    )
  }

  override func hitTest(_: NSPoint) -> NSView? {
    nil
  }

  private func apply(_ presentation: ComposeActionPresentation?) {
    let wasVisible = isActivityVisible
    lastPresentation = presentation
    hasAppliedPresentation = true
    let supported = presentation.flatMap { value in
      ComposeActionAnimationInventory.animation(for: value.action).map { _ in value }
    }
    isActivityVisible = supported != nil
    indicatorView.configure(supported?.action)
    switch mode {
    case .text:
      label.stringValue = supported?.text ?? preview
      label.textColor = supported == nil ? .tertiaryLabelColor : Theme.accentColor
      label.isHidden = false
    case .indicator:
      label.stringValue = ""
      label.isHidden = true
    }
    setAccessibilityLabel(supported?.text)
    if wasVisible != isActivityVisible {
      visibilityChanged?()
    }
    guard allowsAnimations,
          !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    else { return }
    let transition = CATransition()
    transition.type = .fade
    transition.duration = 0.18
    layer?.add(transition, forKey: "sidebar-compose-swap")
  }
}

@MainActor
private final class SidebarNativeComposeIndicatorView: NSView {
  private var action: ApiComposeAction?
  private var indicatorLayers: [CAShapeLayer] = []

  override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(_ action: ApiComposeAction?) {
    guard self.action != action else { return }
    self.action = action
    rebuildLayers()
  }

  func refreshColor() {
    indicatorLayers.forEach { $0.fillColor = Theme.accentColor.cgColor }
  }

  override func layout() {
    super.layout()
    layoutIndicatorLayers()
  }

  private func rebuildLayers() {
    indicatorLayers.forEach { $0.removeFromSuperlayer() }
    indicatorLayers.removeAll()
    guard let action,
          let kind = ComposeActionAnimationInventory.animation(for: action)
    else { return }

    let count = switch kind {
    case .typing, .recordingVoice:
      3
    case .upload:
      1
    }
    for index in 0 ..< count {
      let shape = CAShapeLayer()
      SidebarNativeLayerUpdates.disableImplicitAnimations(on: shape)
      shape.fillColor = Theme.accentColor.cgColor
      layer?.addSublayer(shape)
      indicatorLayers.append(shape)
      guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { continue }
      let animation = CABasicAnimation(keyPath: kind == .typing ? "transform.translation.y" : "transform.scale.y")
      animation.fromValue = kind == .typing ? 0 : 0.45
      animation.toValue = kind == .typing ? -2 : 1
      animation.duration = kind == .upload ? 0.8 : 0.6
      animation.autoreverses = true
      animation.repeatCount = .infinity
      animation.beginTime = CACurrentMediaTime() + Double(index) * 0.12
      shape.add(animation, forKey: "sidebar-compose-pulse")
    }
    needsLayout = true
  }

  private func layoutIndicatorLayers() {
    guard let action,
          let kind = ComposeActionAnimationInventory.animation(for: action)
    else { return }
    switch kind {
    case .typing:
      for (index, shape) in indicatorLayers.enumerated() {
        let rect = CGRect(x: CGFloat(index) * 5, y: bounds.midY - 1.5, width: 3, height: 3)
        shape.frame = rect
        shape.path = CGPath(ellipseIn: CGRect(origin: .zero, size: rect.size), transform: nil)
      }
    case .upload:
      guard let shape = indicatorLayers.first else { return }
      let rect = CGRect(x: 1, y: bounds.midY - 2, width: 14, height: 4)
      shape.frame = rect
      shape.path = CGPath(
        roundedRect: CGRect(origin: .zero, size: rect.size),
        cornerWidth: 2,
        cornerHeight: 2,
        transform: nil
      )
    case .recordingVoice:
      for (index, shape) in indicatorLayers.enumerated() {
        let height = CGFloat(5 + index * 3)
        let rect = CGRect(x: CGFloat(index) * 4.5, y: bounds.midY - height / 2, width: 2.2, height: height)
        shape.frame = rect
        shape.path = CGPath(
          roundedRect: CGRect(origin: .zero, size: rect.size),
          cornerWidth: 1.1,
          cornerHeight: 1.1,
          transform: nil
        )
      }
    }
  }
}

@MainActor
private final class SidebarNativeIdentityView: NSView {
  private let hostedView = SidebarNativeHostedVisualView()

  override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    addSubview(hostedView)
    setAccessibilityElement(false)
    setAccessibilityHidden(true)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(
    identity: ChatListIdentityDescriptor?,
    size: CGFloat,
    hasBackgroundShape: Bool
  ) {
    hostedView.configure {
      SidebarChatIdentityIcon(
        identity: identity,
        size: size,
        shape: hasBackgroundShape ? .circle : .none
      )
      .equatable()
      .frame(width: size, height: size)
    }
    needsLayout = true
  }

  func configure(user: SidebarNativeRowConfiguration.Avatar, size: CGFloat) {
    hostedView.configure {
      UserAvatar(
        userID: user.userID,
        firstName: user.firstName,
        lastName: user.lastName,
        email: user.email,
        username: user.username,
        stableAvatarIdentity: user.stableAvatarIdentity,
        remoteURL: user.remoteURL,
        localURL: user.localURL,
        size: size
      )
      .equatable()
      .frame(width: size, height: size)
    }
    needsLayout = true
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    hostedView.prepareForReuse()
  }

  override func layout() {
    super.layout()
    hostedView.frame = bounds
  }

  override func hitTest(_: NSPoint) -> NSView? {
    nil
  }
}
