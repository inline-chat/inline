import AppKit
import InlineContextMenu

enum LabMode: String, CaseIterable {
  /// The menu we ship today.
  case native
  /// Native menu with an NSMenu palette (presentationStyle = .palette) of emoji as the first row.
  case palette
  /// Native menu with the emoji bar as an NSMenuItem.view first row.
  case viewRow
  /// Native menu plus the emoji bar in its own floating panel beside it.
  case nativePanel
  /// Our panels via InlineContextMenu, emoji bar as an accessory above the menu.
  case custom

  var title: String {
    switch self {
    case .native: "Native"
    case .palette: "Palette row"
    case .viewRow: "View row"
    case .nativePanel: "Native + panel"
    case .custom: "Custom"
    }
  }
}

@MainActor
final class LabController: NSObject, NSMenuDelegate, NSMenuItemValidation {
  var mode: LabMode = .native
  var animation: ContextMenuOptions.Animation = .pop
  var material: ContextMenuMaterial = .automatic
  enum Interception: String, CaseIterable {
    /// Present from menu(for:) and return nil. Public API only.
    case menuForEvent
    /// Let AppKit start the native menu, cancel it in willOpenMenu, present ours.
    case willOpenCancel
    /// Return InlineContextMenu and rely on the class popUpContextMenu override.
    case classOverride
  }

  var interception: Interception = .menuForEvent
  /// Event types menu(for:) was called with, to spot speculative calls (accessibility, services).
  var menuForEventCalls: [String] = []
  private var presentingCustom = false

  private(set) var logLines: [String] = []
  private(set) var actions: [String] = []
  var onLog: ((String) -> Void)?
  /// Probe hooks.
  var highlightTrail: [String] = []
  var panelEvents: [String] = []
  var nativeTrackingBeganAt: TimeInterval?
  var lastMenuEventTimestamp: TimeInterval?

  private var targetBubble: NSView?
  private var floatingPanel: ContextMenuPanel?
  private let started = CACurrentMediaTime()

  override init() {
    super.init()
    NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { [weak self] note in
      MainActor.assumeIsolated {
        guard let self else { return }
        let isOurs = note.object is ContextMenu
        self.nativeTrackingBeganAt = ProcessInfo.processInfo.systemUptime
        if !isOurs, let ts = self.lastMenuEventTimestamp {
          self.log(String(format: "native didBeginTracking %.1fms after the click", (ProcessInfo.processInfo.systemUptime - ts) * 1000))
        }
      }
    }
    ContextMenu.presentationObserver = { [weak self] entry in
      MainActor.assumeIsolated { self?.log("intercepted via \(entry)") }
    }
  }

  func log(_ line: String) {
    let stamped = String(format: "%7.3f  ", CACurrentMediaTime() - started) + line
    logLines.append(stamped)
    onLog?(stamped)
  }

  // MARK: Menus

  func menu(for view: NSView, event: NSEvent, nativeTextMenu: NSMenu?) -> NSMenu? {
    targetBubble = view
    lastMenuEventTimestamp = event.timestamp
    let kind = event.type == .rightMouseDown ? "right" : event.type == .leftMouseDown ? "ctrl-left" : "type\(event.type.rawValue)"
    menuForEventCalls.append(kind)
    log("menu(for:) \(kind) current=\(NSApp.currentEvent === event) mode=\(mode.rawValue)")
    let message = (view as? BubbleView)?.message ?? (view as? TextBubbleView)?.message
    let menu: NSMenu
    switch mode {
    case .custom:
      let custom = ContextMenu()
      custom.usesCustomPresentation = interception == .classOverride
      var options = ContextMenuOptions()
      options.animation = animation
      options.material = material
      options.log = { [weak self] in self?.log("session: \($0)") }
      custom.options = options
      custom.accessoryViewProvider = { [weak self] in self?.makeReactionBar(style: .accessory) }
      // As the app places its reactions bar (MessageReactionActions.contextMenuAccessoryConfiguration).
      custom.options.accessoryConfiguration = ContextMenuAccessoryConfiguration(alignment: .trailing, spacing: 10, offset: 30)
      menu = custom
    default:
      menu = NSMenu()
    }
    menu.delegate = self
    buildMessageItems(into: menu, message: message, nativeTextMenu: nativeTextMenu)

    switch mode {
    case .palette:
      let palette = NSMenu()
      palette.presentationStyle = .palette
      for emoji in ReactionBarView.defaultEmoji {
        let item = NSMenuItem(title: emoji, action: #selector(reactFromMenu(_:)), keyEquivalent: "")
        item.target = self
        item.image = emojiImage(emoji, size: 22)
        item.representedObject = emoji
        palette.addItem(item)
      }
      let holder = NSMenuItem(title: "Reactions", action: nil, keyEquivalent: "")
      holder.submenu = palette
      menu.insertItem(holder, at: 0)
      menu.insertItem(.separator(), at: 1)
    case .viewRow:
      let row = NSMenuItem()
      row.view = makeReactionBar(style: .menuRow)
      menu.insertItem(row, at: 0)
      menu.insertItem(.separator(), at: 1)
    default:
      break
    }
    if mode == .custom, interception == .menuForEvent, let custom = menu as? ContextMenu {
      custom.usesCustomPresentation = true
      return ContextMenu.intercept(custom, for: event, in: view)
    }
    return menu
  }

  /// The willOpenCancel strategy: AppKit has asked the view to open the native menu; stop it and show ours.
  func interceptWillOpen(_ menu: NSMenu, event: NSEvent, view: NSView) {
    guard mode == .custom, interception == .willOpenCancel, !presentingCustom, let custom = menu as? ContextMenu else { return }
    menu.cancelTrackingWithoutAnimation()
    log("willOpenMenu: cancelled native, presenting custom")
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.presentingCustom = true
      defer { self.presentingCustom = false }
      var options = custom.options
      options.accessoryView = custom.accessoryViewProvider?()
      ContextMenuSession.popUp(custom, with: event, for: view, options: options)
    }
  }

  func makeReactionBar(style: ReactionBarView.Style) -> ReactionBarView {
    let bar = ReactionBarView(style: style)
    bar.onPick = { [weak self] emoji in
      self?.react(emoji)
      ContextMenuSession.current?.close(animated: true, reason: .action)
      bar.enclosingMenuItem?.menu?.cancelTracking()
    }
    bar.onMore = { [weak self] in
      self?.log("more reactions")
      ContextMenuSession.current?.close(animated: true, reason: .action)
      bar.enclosingMenuItem?.menu?.cancelTracking()
    }
    bar.eventCounter = { [weak self] kind in
      self?.panelEvents.append(kind)
    }
    return bar
  }

  /// The items MessageViewAppKit.createMessageMenu builds, regrouped: answer (reply, thread, forward),
  /// copy, change (edit, pin, select), integrations, the text view's own items, then Delete and the
  /// edit time as a footnote. Edit only shows on our own messages, as in the app. "Add Reaction…" goes
  /// when the reactions are the accessory: the bar's + opens the full picker, and Up from Reply reaches it.
  func buildMessageItems(into menu: NSMenu, message: LabMessage?, nativeTextMenu: NSMenu?) {
    func add(_ title: String, _ action: Selector?, key: String = "", symbol: String? = nil, effect: ContextMenuIconEffect? = nil) -> NSMenuItem {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
      item.target = self
      if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
      item.contextMenuIconEffect = effect
      menu.addItem(item)
      return item
    }
    let reactionsInAccessory = mode == .custom

    _ = add("Reply", #selector(labAction(_:)), key: "r", symbol: "arrowshape.turn.up.left")
    _ = add("Reply in Thread", #selector(labAction(_:)), symbol: "bubble.left.and.text.bubble.right")
    let forward = add("Forward", nil, symbol: "arrowshape.turn.up.right")
    let chats = NSMenu(title: "Forward")
    chats.delegate = self
    chats.addItem(NSMenuItem.sectionHeader(title: "Recent"))
    for chat in ["Design", "Mo", "Engineering", "Launch"] {
      let item = NSMenuItem(title: chat, action: #selector(labAction(_:)), keyEquivalent: "")
      item.target = self
      item.image = NSImage(systemSymbolName: "bubble.left", accessibilityDescription: nil)
      chats.addItem(item)
    }
    chats.addItem(.separator())
    let more = NSMenuItem(title: "Choose Chat…", action: #selector(labAction(_:)), keyEquivalent: "")
    more.target = self
    chats.addItem(more)
    forward.submenu = chats
    if !reactionsInAccessory {
      _ = add("Add Reaction…", #selector(labAction(_:)), symbol: "face.smiling")
    }

    menu.addItem(.separator())
    _ = add("Copy Text", #selector(labAction(_:)), key: "c", symbol: "document.on.document")
    let entities = add("Copy Message + Entities", #selector(labAction(_:)), key: "c")
    entities.keyEquivalentModifierMask = [.command, .option]
    entities.isAlternate = true
    if let nativeTextMenu, let copy = nativeTextMenu.items.first(where: { $0.action == #selector(NSText.copy(_:)) }) {
      let item = copy.copy() as! NSMenuItem
      item.title = "Copy Selected Text"
      item.image = NSImage(systemSymbolName: "text.cursor", accessibilityDescription: nil)
      menu.addItem(item)
    }
    _ = add("Copy Message Link", #selector(labAction(_:)), symbol: "link")

    menu.addItem(.separator())
    if message?.outgoing ?? true {
      _ = add("Edit", #selector(labAction(_:)), key: "e", symbol: "pencil")
    }
    _ = add("Pin", #selector(labAction(_:)), symbol: "pin")
    _ = add("Select", #selector(labAction(_:)), symbol: "checkmark.circle")

    menu.addItem(.separator())
    _ = add("Create Linear Issue", #selector(labAction(_:)), symbol: "circle.badge.plus")
    let mark = NSMenuItem(title: "Mark", action: #selector(BubbleView.markFromMenu(_:)), keyEquivalent: "")
    mark.image = NSImage(systemSymbolName: "bookmark", accessibilityDescription: nil)
    menu.addItem(mark) // no target: resolved from the clicked view

    if let nativeTextMenu {
      menu.addItem(.separator())
      for item in nativeTextMenu.items where item.title.hasPrefix("Look Up") || item.title.hasPrefix("Translate") {
        let copy = item.copy() as! NSMenuItem
        if copy.title.hasPrefix("Look Up") { copy.image = NSImage(systemSymbolName: "character.book.closed", accessibilityDescription: nil) }
        if copy.title.hasPrefix("Translate") { copy.image = NSImage(systemSymbolName: "translate", accessibilityDescription: nil) }
        menu.addItem(copy)
      }
    }

    menu.addItem(.separator())
    let delete = add("Delete", #selector(labAction(_:)), key: "\u{8}", symbol: "trash")
    delete.contextMenuStyle = .destructive
    if message?.edited == true {
      let edited = NSMenuItem(title: "Edited Nov 26 at 7:30 PM", action: nil, keyEquivalent: "")
      edited.isEnabled = false
      edited.contextMenuStyle = .footnote
      menu.addItem(edited)
    }
  }

  // MARK: Actions

  @objc func labAction(_ sender: NSMenuItem) {
    actions.append(sender.title)
    log("ACTION \(sender.title)")
  }

  @objc func reactFromMenu(_ sender: NSMenuItem) {
    if let emoji = sender.representedObject as? String { react(emoji) }
  }

  func react(_ emoji: String) {
    actions.append("react \(emoji)")
    log("REACT \(emoji)")
    if let bubble = targetBubble as? BubbleView {
      bubble.message.reactions.append(emoji)
    }
  }

  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    // Edit is for our own messages, as in the app; validation must reach the custom menu too.
    if item.title == "Edit" {
      return (targetBubble as? BubbleView)?.message.outgoing ?? false
    }
    // A chat without Linear connected, so the lab always shows one disabled item.
    if item.title == "Create Linear Issue" {
      return (targetBubble as? BubbleView)?.message.id != 1
    }
    return true
  }

  // MARK: NSMenuDelegate

  func menuNeedsUpdate(_ menu: NSMenu) {
    log("delegate menuNeedsUpdate \(menu.title.isEmpty ? "root" : menu.title)")
  }

  func menuWillOpen(_ menu: NSMenu) {
    log("delegate menuWillOpen \(menu.title.isEmpty ? "root" : menu.title)")
    highlightTrail = []
    if mode == .nativePanel, menu.supermenu == nil {
      showFloatingPanel()
    }
  }

  func menuDidClose(_ menu: NSMenu) {
    log("delegate menuDidClose \(menu.title.isEmpty ? "root" : menu.title)")
    if mode == .nativePanel, menu.supermenu == nil {
      floatingPanel?.orderOut(nil)
    }
  }

  func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
    highlightTrail.append(item?.title ?? "-")
  }

  /// The emoji bar in its own panel, shown while a native menu tracks.
  private func showFloatingPanel() {
    let bar = makeReactionBar(style: .accessory)
    let panel = ContextMenuPanel()
    let host = NSVisualEffectView(frame: NSRect(origin: .zero, size: bar.fittingSize))
    host.material = .menu
    host.state = .active
    host.wantsLayer = true
    host.layer?.cornerRadius = bar.fittingSize.height / 2
    host.layer?.masksToBounds = true
    bar.frame = host.bounds
    host.addSubview(bar)
    panel.contentView = host
    panel.setContentSize(bar.fittingSize)
    let mouse = NSEvent.mouseLocation
    panel.setFrameOrigin(NSPoint(x: mouse.x, y: mouse.y + 10))
    panel.orderFront(nil)
    floatingPanel = panel
    panelEvents = []
  }
}
