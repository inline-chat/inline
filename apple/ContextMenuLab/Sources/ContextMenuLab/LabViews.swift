import AppKit
import InlineContextMenu

// MARK: - Messages

struct LabMessage {
  let id: Int
  let text: String
  let outgoing: Bool
  var reactions: [String] = []
  var edited = false
}

/// A message bubble. Its menu comes from `menu(for:)`, as MessageViewAppKit's does.
final class BubbleView: NSView {
  var message: LabMessage { didSet { needsDisplay = true; invalidateIntrinsicContentSize() } }
  weak var lab: LabController?
  private var menuOpen = false { didSet { needsDisplay = true } }

  init(message: LabMessage, lab: LabController) {
    self.message = message
    self.lab = lab
    super.init(frame: .zero)
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel(message.text)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  private var textAttributes: [NSAttributedString.Key: Any] {
    [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: message.outgoing ? NSColor.white : NSColor.labelColor]
  }

  override var intrinsicContentSize: NSSize {
    let size = (message.text as NSString).boundingRect(with: NSSize(width: 320, height: 1000), options: [.usesLineFragmentOrigin], attributes: textAttributes).size
    return NSSize(width: ceil(size.width) + 24, height: ceil(size.height) + 16 + (message.reactions.isEmpty ? 0 : 26))
  }

  override func draw(_ dirtyRect: NSRect) {
    let textHeight = bounds.height - (message.reactions.isEmpty ? 0 : 26)
    let bubble = NSRect(x: 0, y: 0, width: bounds.width, height: textHeight)
    (message.outgoing ? NSColor.controlAccentColor : NSColor.quaternaryLabelColor).setFill()
    NSBezierPath(roundedRect: bubble, xRadius: 14, yRadius: 14).fill()
    if menuOpen {
      NSColor.black.withAlphaComponent(0.12).setFill()
      NSBezierPath(roundedRect: bubble, xRadius: 14, yRadius: 14).fill()
    }
    (message.text as NSString).draw(with: bubble.insetBy(dx: 12, dy: 8), options: [.usesLineFragmentOrigin], attributes: textAttributes)
    if !message.reactions.isEmpty {
      let chips = Dictionary(grouping: message.reactions, by: { $0 }).map { "\($0.key) \($0.value.count)" }.sorted().joined(separator: "  ")
      (chips as NSString).draw(at: NSPoint(x: 4, y: textHeight + 4), withAttributes: [.font: NSFont.systemFont(ofSize: 13)])
    }
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    lab?.menu(for: self, event: event, nativeTextMenu: nil)
  }

  /// An action only the bubble answers: menu items with no target must reach it, as AppKit sends a
  /// context menu's untargeted items up the clicked view's responder chain.
  @objc func markFromMenu(_ sender: NSMenuItem) {
    lab?.labAction(sender)
  }

  /// VoiceOver's show-menu on a plain view does not go through menu(for:), so route it there.
  override func accessibilityPerformShowMenu() -> Bool {
    guard let window else { return false }
    let point = convert(NSPoint(x: min(40, bounds.midX), y: bounds.midY), to: nil)
    guard let event = NSEvent.mouseEvent(
      with: .rightMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
    ) else { return false }
    if let menu = menu(for: event) {
      NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    return true
  }

  override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
    menuOpen = true
    lab?.log("view willOpenMenu \(type(of: menu))")
    lab?.interceptWillOpen(menu, event: event, view: self)
  }

  override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
    menuOpen = false
    lab?.log("view didCloseMenu")
  }
}

/// A selectable text message, for menus that merge the text view's own items (Look Up, Translate, Copy).
final class TextBubbleView: NSView, NSTextViewDelegate {
  let textView = NSTextView()
  var message: LabMessage
  weak var lab: LabController?

  init(message: LabMessage, lab: LabController) {
    self.message = message
    self.lab = lab
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 14
    layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
    textView.string = message.text
    textView.isEditable = false
    textView.isSelectable = true
    textView.drawsBackground = false
    textView.font = .systemFont(ofSize: 13)
    textView.textContainerInset = NSSize(width: 8, height: 8)
    textView.delegate = self
    textView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(textView)
    NSLayoutConstraint.activate([
      textView.leadingAnchor.constraint(equalTo: leadingAnchor),
      textView.trailingAnchor.constraint(equalTo: trailingAnchor),
      textView.topAnchor.constraint(equalTo: topAnchor),
      textView.bottomAnchor.constraint(equalTo: bottomAnchor),
      widthAnchor.constraint(equalToConstant: 340),
      heightAnchor.constraint(equalToConstant: 56),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
    lab?.menu(for: self, event: event, nativeTextMenu: menu)
  }
}

// MARK: - Reaction bar

/// The quick reactions, shown as the context menu's accessory view (as on iOS), as a native menu view
/// item, and as the floating panel beside a native menu.
final class ReactionBarView: NSView, ContextMenuAccessoryInteraction {
  enum Style {
    case accessory
    case menuRow
  }

  static let defaultEmoji = ["👍", "❤️", "😂", "🔥", "🎉", "👀", "🙏"]

  let emoji: [String]
  let style: Style
  var onPick: ((String) -> Void)?
  var onMore: (() -> Void)?
  var eventCounter: ((String) -> Void)?
  private var hovered: Int? { didSet { if oldValue != hovered { needsDisplay = true } } }
  private var pressed: Int?
  /// Keyboard focus from the menu (Up from its first row).
  private(set) var keyboardIndex: Int? {
    didSet {
      guard oldValue != keyboardIndex else { return }
      needsDisplay = true
      if let keyboardIndex, let element = elements[safe: keyboardIndex] {
        NSAccessibility.post(element: element, notification: .focusedUIElementChanged)
      }
    }
  }

  private let cell: CGFloat
  private let inset: CGFloat
  private lazy var elements: [ReactionElement] = (0 ... emoji.count).map { index in
    let label = index == emoji.count ? "More reactions" : "React with \(emoji[index])"
    return ReactionElement(label: label, parent: self, frame: { [weak self] in self?.cellRect(index) ?? .zero }) { [weak self] in
      self?.pick(index)
    }
  }

  init(emoji: [String] = ReactionBarView.defaultEmoji, style: Style) {
    self.emoji = emoji
    self.style = style
    cell = style == .accessory ? 36 : 30
    inset = style == .accessory ? 5 : 10
    super.init(frame: NSRect(origin: .zero, size: NSSize(width: 0, height: 0)))
    setFrameSize(fittingSize)
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("Reactions")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var fittingSize: NSSize {
    NSSize(width: CGFloat(emoji.count + 1) * cell + 2 * inset, height: cell + 2 * (style == .accessory ? 4 : 3))
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self))
  }

  fileprivate func cellRect(_ index: Int) -> NSRect {
    NSRect(x: inset + CGFloat(index) * cell, y: (bounds.height - cell) / 2, width: cell, height: cell)
  }

  private func index(at point: NSPoint) -> Int? {
    (0 ... emoji.count).first { cellRect($0).contains(point) }
  }

  override func draw(_ dirtyRect: NSRect) {
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    for index in 0 ... emoji.count {
      let rect = cellRect(index)
      let active = hovered == index || keyboardIndex == index
      if active {
        NSColor.labelColor.withAlphaComponent(0.1).setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
      }
      if keyboardIndex == index {
        NSColor.keyboardFocusIndicatorColor.setStroke()
        let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
        ring.lineWidth = 2
        ring.stroke()
      }
      if index == emoji.count {
        if let plus = NSImage(systemSymbolName: "plus", accessibilityDescription: "More reactions")?.withSymbolConfiguration(.init(pointSize: 14, weight: .medium)) {
          let size = plus.size
          let tinted = NSImage(size: size, flipped: false) { r in plus.draw(in: r); NSColor.secondaryLabelColor.set(); r.fill(using: .sourceAtop); return true }
          tinted.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        continue
      }
      let scale: CGFloat = active && !reduceMotion ? 1.2 : 1
      let font = NSFont.systemFont(ofSize: (style == .accessory ? 22 : 19) * scale)
      let text = emoji[index] as NSString
      let size = text.size(withAttributes: [.font: font])
      text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: [.font: font])
    }
  }

  override func mouseMoved(with event: NSEvent) {
    hovered = index(at: convert(event.locationInWindow, from: nil))
    eventCounter?("mouseMoved")
  }

  override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
  override func mouseExited(with event: NSEvent) { hovered = nil }

  override func mouseDown(with event: NSEvent) {
    eventCounter?("mouseDown")
    pressed = index(at: convert(event.locationInWindow, from: nil))
  }

  override func mouseUp(with event: NSEvent) {
    eventCounter?("mouseUp")
    let index = index(at: convert(event.locationInWindow, from: nil))
    defer { pressed = nil }
    guard let index, index == pressed else { return }
    pick(index)
  }

  fileprivate func pick(_ index: Int) {
    if index == emoji.count {
      onMore?()
    } else {
      onPick?(emoji[index])
    }
  }

  // MARK: ContextMenuAccessoryInteraction

  func contextMenuTrackPointer(atScreen point: NSPoint?) {
    guard let point, let window else { hovered = nil; return }
    hovered = index(at: convert(window.convertPoint(fromScreen: point), from: nil))
  }

  func contextMenuRelease(atScreen point: NSPoint) -> Bool {
    guard let window, let index = index(at: convert(window.convertPoint(fromScreen: point), from: nil)) else { return false }
    pick(index)
    return true
  }

  func contextMenuSetKeyboardFocus(_ focused: Bool) -> Bool {
    keyboardIndex = focused ? 0 : nil
    hovered = nil
    return true
  }

  func contextMenuMoveKeyboardFocus(by step: Int) {
    guard let keyboardIndex else { return }
    self.keyboardIndex = min(max(keyboardIndex + step, 0), emoji.count)
  }

  func contextMenuActivateKeyboardFocus() -> Bool {
    guard let keyboardIndex else { return false }
    pick(keyboardIndex)
    return true
  }

  // MARK: Accessibility

  override func accessibilityChildren() -> [Any]? { elements }
}

/// One reaction as VoiceOver sees it: a button that reacts when pressed.
final class ReactionElement: NSAccessibilityElement {
  private let frameInParent: () -> NSRect
  private let press: () -> Void
  private weak var parentView: NSView?

  init(label: String, parent: NSView, frame: @escaping () -> NSRect, press: @escaping () -> Void) {
    frameInParent = frame
    self.press = press
    parentView = parent
    super.init()
    setAccessibilityRole(.button)
    setAccessibilityLabel(label)
    setAccessibilityParent(parent)
  }

  override func accessibilityFrame() -> NSRect {
    guard let parentView, let window = parentView.window else { return .zero }
    return window.convertToScreen(parentView.convert(frameInParent(), to: nil))
  }

  override func accessibilityPerformPress() -> Bool {
    press()
    return true
  }
}

extension Array {
  subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// An emoji as a menu image, for the palette approach.
func emojiImage(_ emoji: String, size: CGFloat = 20) -> NSImage {
  let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
    let font = NSFont.systemFont(ofSize: size * 0.82)
    let text = emoji as NSString
    let textSize = text.size(withAttributes: [.font: font])
    text.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2), withAttributes: [.font: font])
    return true
  }
  image.isTemplate = false
  image.accessibilityDescription = emoji
  return image
}
