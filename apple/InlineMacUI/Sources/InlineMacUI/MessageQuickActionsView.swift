import AppKit

/// A single, list-owned accessory; its frame never participates in message measurement.
@MainActor
public final class MessageQuickActionsView: NSView {
  public enum Action: Int, CaseIterable {
    case replyInThread, reaction, more

    fileprivate var title: String {
      switch self {
        case .replyInThread: "Reply in Thread"
        case .reaction: "Add Reaction"
        case .more: "More Actions"
      }
    }
  }

  // Match the small control scale of the native unified-compact toolbar.
  public static let preferredSize = NSSize(width: 74, height: 26)
  public var onAction: ((Action, NSButton) -> Void)?
  private let surfaceView: NSView
  private let buttonContainer: NSView
  private var buttons: [MessageQuickActionButton] = []
  private var cursorTrackingArea: NSTrackingArea?

  public override init(frame frameRect: NSRect) {
    let buttonContainer = NSView()
    self.buttonContainer = buttonContainer
    if #available(macOS 26.0, *) {
      let glass = NSGlassEffectView()
      glass.style = .regular
      glass.cornerRadius = Self.preferredSize.height / 2
      glass.contentView = buttonContainer
      if #available(macOS 27.0, *) {
        glass.effectIsInteractive = true
      }
      surfaceView = glass
    } else {
      let surfaceView = NSView()
      surfaceView.wantsLayer = true
      surfaceView.layer?.cornerRadius = Self.preferredSize.height / 2
      surfaceView.addSubview(buttonContainer)
      self.surfaceView = surfaceView
    }

    super.init(frame: frameRect)
    wantsLayer = true
    clipsToBounds = false
    layer?.masksToBounds = false
    layer?.shadowColor = NSColor.black.cgColor
    layer?.shadowOpacity = 0.1
    layer?.shadowRadius = 4
    layer?.shadowOffset = NSSize(width: 0, height: -2)
    layer?.shadowPath = CGPath(
      roundedRect: NSRect(origin: .zero, size: Self.preferredSize),
      cornerWidth: Self.preferredSize.height / 2,
      cornerHeight: Self.preferredSize.height / 2,
      transform: nil
    )
    addSubview(surfaceView)
    surfaceView.frame = bounds
    surfaceView.autoresizingMask = [.width, .height]
    buttonContainer.frame = bounds
    buttonContainer.autoresizingMask = [.width, .height]

    for action in Action.allCases {
      let button = MessageQuickActionButton(
        image: Self.image(for: action), target: self, action: #selector(performAction(_:))
      )
      button.tag = action.rawValue
      button.isBordered = false
      button.bezelStyle = .smallSquare
      button.imagePosition = .imageOnly
      button.imageScaling = .scaleProportionallyDown
      button.controlSize = .small
      button.contentTintColor = .secondaryLabelColor
      button.setButtonType(.momentaryChange)
      button.setAccessibilityLabel(action.title)
      button.setInlineTooltip(verbatim: action.title)
      button.frame = NSRect(x: 2 + CGFloat(action.rawValue) * 24, y: 2, width: 22, height: 22)
      button.wantsLayer = true
      button.layer?.cornerRadius = 11
      buttonContainer.addSubview(button)
      buttons.append(button)
    }
    updateAppearance()
  }

  @available(*, unavailable)
  public required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  public func setActionsEnabled(canReply: Bool, canReact: Bool) {
    buttons[Action.replyInThread.rawValue].isEnabled = canReply
    buttons[Action.reaction.rawValue].isEnabled = canReact
  }

  public func setActiveAction(_ action: Action?) {
    for button in buttons {
      button.isActive = action?.rawValue == button.tag
    }
  }

  public func hideTooltips() {
    buttons.forEach { $0.hideInlineTooltip() }
  }

  public func refreshHoverState() {
    buttons.forEach { $0.refreshHoverState() }
    window?.invalidateCursorRects(for: self)
    setArrowCursorIfInside()
  }

  public override func resetCursorRects() {
    super.resetCursorRects()
    guard !isHiddenOrHasHiddenAncestor else { return }
    addCursorRect(bounds, cursor: .arrow)
  }

  public override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let cursorTrackingArea {
      removeTrackingArea(cursorTrackingArea)
    }
    let area = NSTrackingArea(
      rect: .zero,
      options: [.cursorUpdate, .activeInActiveApp, .inVisibleRect],
      owner: self
    )
    addTrackingArea(area)
    cursorTrackingArea = area
  }

  public override func cursorUpdate(with event: NSEvent) {
    setArrowCursorIfInside()
  }

  private func setArrowCursorIfInside() {
    guard !isHiddenOrHasHiddenAncestor, let window,
          bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) else { return }
    NSCursor.arrow.set()
  }

  public override func rightMouseDown(with event: NSEvent) {
    hideTooltips()
    onAction?(.more, buttons[Action.more.rawValue])
  }

  public override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateAppearance()
  }

  private func updateAppearance() {
    if #unavailable(macOS 26.0) {
      effectiveAppearance.performAsCurrentDrawingAppearance {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        surfaceView.layer?.backgroundColor = (isDark ? NSColor.controlBackgroundColor : .white).cgColor
      }
    }
  }

  @objc private func performAction(_ sender: NSButton) {
    guard let action = Action(rawValue: sender.tag) else { return }
    hideTooltips()
    onAction?(action, sender)
  }

  private static func image(for action: Action) -> NSImage {
    let symbol: String = switch action {
      case .reaction: "face.smiling"
      case .more: "ellipsis"
      case .replyInThread: "arrow.turn.down.right"
    }
    let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
    return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!
      .withSymbolConfiguration(configuration)!
  }
}

@MainActor
private final class MessageQuickActionButton: NSButton {
  private var hoverTrackingArea: NSTrackingArea?
  private var isHovered = false
  var isActive = false {
    didSet { updateHoverFill() }
  }

  override var isEnabled: Bool {
    didSet { refreshHoverState() }
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverTrackingArea {
      removeTrackingArea(hoverTrackingArea)
    }
    let area = NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .cursorUpdate, .activeInActiveApp, .inVisibleRect],
      owner: self
    )
    addTrackingArea(area)
    hoverTrackingArea = area
  }

  override func mouseEntered(with event: NSEvent) {
    refreshHoverState()
  }

  override func mouseExited(with event: NSEvent) {
    isHovered = false
    updateHoverFill()
  }

  override func viewDidHide() {
    super.viewDidHide()
    isHovered = false
    updateHoverFill()
  }

  override func resetCursorRects() {
    super.resetCursorRects()
    guard !isHiddenOrHasHiddenAncestor else { return }
    addCursorRect(bounds, cursor: .arrow)
  }

  override func cursorUpdate(with event: NSEvent) {
    refreshHoverState()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateHoverFill()
  }

  func refreshHoverState() {
    guard !isHiddenOrHasHiddenAncestor, let window else {
      isHovered = false
      updateHoverFill()
      return
    }
    isHovered = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    if isHovered {
      NSCursor.arrow.set()
    }
    updateHoverFill()
  }

  private func updateHoverFill() {
    // Same light circular hover treatment as the composer's Add button.
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = (isHovered || isActive) && isEnabled
        ? NSColor.gray.withAlphaComponent(0.1).cgColor
        : NSColor.clear.cgColor
    }
  }
}
