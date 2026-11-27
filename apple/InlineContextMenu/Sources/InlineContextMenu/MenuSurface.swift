import AppKit
import ObjectiveC
import Symbols

// MARK: - Metrics and appearance

/// Sizes. The defaults follow AppKit's menu (measured on macOS 27: 13 pt text at x 35, symbols at their
/// natural ~13 pt in a 15 pt column at x 15, 11 pt separators, 12 pt corners), with taller rows.
public struct ContextMenuMetrics {
  /// AppKit uses 24; 28 gives the pointer and the eye more room (Telegram uses 28 too).
  public var rowHeight: CGFloat = 28
  public var subtitleRowHeight: CGFloat = 40
  public var footnoteRowHeight: CGFloat = 22
  public var separatorHeight: CGFloat = 11
  public var headerHeight: CGFloat = 26
  public var verticalPadding: CGFloat = 6
  /// Inset of the highlight from the menu edge.
  public var highlightInset: CGFloat = 5
  /// AppKit uses 7. Concentric with the 15 pt menu corners at the 5 pt inset.
  public var highlightRadius: CGFloat = 10
  /// Padding inside the highlight before the first column and after the last.
  public var contentPadding: CGFloat = 9
  /// The icon column. Symbols draw at their natural size for `iconPointSize`, centered in it.
  public var iconColumnWidth: CGFloat = 20
  /// AppKit draws menu symbols at 13 pt, small scale, regular weight (an arrow is 13 × 12 pt). A size
  /// up and a weight up reads better with the taller rows.
  public var iconPointSize: CGFloat = 14
  public var iconScale: NSImage.SymbolScale = .small
  public var iconWeight: NSFont.Weight = .medium
  public var iconGap: CGFloat = 6
  public var stateColumnWidth: CGFloat = 16
  public var shortcutGap: CGFloat = 32
  /// Width of the key column: keys right-align in it and modifiers end where it starts, so ⌘ lines up
  /// down the menu as in AppKit.
  public var keyColumnWidth: CGFloat = 12
  public var minWidth: CGFloat = 210
  public var maxWidth: CGFloat = 420
  /// AppKit's menu glass uses 12; ours is rounder.
  public var cornerRadius: CGFloat = 15
  /// Where the menu's top-left sits from the pointer. AppKit opens its menu 1 pt right and 6 pt up, so
  /// the pointer rests on the first row's top edge.
  public var pointerOffset = NSPoint(x: 1, y: 6)
  /// Transparent margin around every surface so shadows and pop animations are not clipped.
  public var shadowMargin: CGFloat = 28
  public init() {}
}

public enum ContextMenuMaterial {
  /// The menu glass on macOS 26 and later, the menu vibrancy material before.
  case automatic
  case vibrancy
  case glass
}

public enum ContextMenuItemStyle {
  case normal
  /// Red title, icon and highlight.
  case destructive
  /// Small secondary text that never highlights, for lines such as "Edited 7:30 PM".
  case footnote
}

/// A one-shot SF Symbols effect played on an item's icon when the item highlights.
/// Skipped when Reduce Motion is on, and for icons that are not symbols.
public enum ContextMenuIconEffect {
  case none
  case bounceUp
  case bounceDown
  case wiggleLeft
  case wiggleRight
  case wiggleClockwise
  case wiggleForward
  case rotate
}

nonisolated(unsafe) private var styleKey: UInt8 = 0
nonisolated(unsafe) private var effectKey: UInt8 = 0

public extension NSMenuItem {
  /// Extra presentation the native menu cannot draw. Ignored by the native menu.
  var contextMenuStyle: ContextMenuItemStyle {
    get {
      switch objc_getAssociatedObject(self, &styleKey) as? Int {
      case 1: .destructive
      case 2: .footnote
      default: .normal
      }
    }
    set {
      let raw = switch newValue {
      case .normal: 0
      case .destructive: 1
      case .footnote: 2
      }
      objc_setAssociatedObject(self, &styleKey, raw, .OBJC_ASSOCIATION_RETAIN)
    }
  }

  /// The icon's hover effect. Nil uses the menu's default (`ContextMenuOptions.defaultIconEffect`).
  var contextMenuIconEffect: ContextMenuIconEffect? {
    get { objc_getAssociatedObject(self, &effectKey) as? ContextMenuIconEffect }
    set { objc_setAssociatedObject(self, &effectKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
  }
}

// MARK: - Panel

/// A borderless panel that never takes key or main, so the chat window keeps its first responder,
/// its selection highlight and its active title bar while the menu is up.
public final class ContextMenuPanel: NSPanel {
  public init() {
    super.init(
      contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: true
    )
    isFloatingPanel = true
    level = .popUpMenu
    backgroundColor = .clear
    isOpaque = false
    hasShadow = false
    hidesOnDeactivate = false
    becomesKeyOnlyIfNeeded = true
    isReleasedWhenClosed = false
    animationBehavior = .none
    acceptsMouseMovedEvents = true
    collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary, .moveToActiveSpace]
  }

  override public var canBecomeKey: Bool { false }
  override public var canBecomeMain: Bool { false }

  /// AppKit's menu windows (`NSPopupMenuWindow`, `_NSGlassEffectWindow`) answer yes here though they are
  /// never key. Glass reads it: without it a panel that cannot become key gets the inactive glass,
  /// which drops the vibrant fill and looks dark and flat. Private selector; unused if AppKit drops it.
  @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
}

/// Panels are kept after a menu closes: creating the window device on first order-front is the
/// largest part of opening a menu.
@MainActor
public enum ContextMenuPanelPool {
  private static var free: [ContextMenuPanel] = []
  public static var enabled = true

  static func take() -> ContextMenuPanel {
    if enabled, let panel = free.popLast() { return panel }
    return ContextMenuPanel()
  }

  static func give(_ panel: ContextMenuPanel) {
    panel.orderOut(nil)
    guard enabled, free.count < 4 else { return }
    panel.contentView = nil
    panel.alphaValue = 1
    panel.ignoresMouseEvents = false
    free.append(panel)
  }

  /// Creates panels and their window devices ahead of the first menu.
  public static func prewarm(count: Int = 2) {
    guard enabled else { return }
    for _ in 0 ..< count where free.count < 4 {
      let panel = ContextMenuPanel()
      panel.setFrame(NSRect(x: -10_000, y: -10_000, width: 10, height: 10), display: false)
      panel.alphaValue = 0
      panel.orderFront(nil)
      panel.orderOut(nil)
      free.append(panel)
    }
  }
}

// MARK: - Chrome

/// Shadow, material and rim around a surface's content. Content sits inset by the shadow margin.
final class ContextMenuChromeView: NSView {
  let contentContainer = NSView()
  /// The shadow only outside the body: glass is translucent and samples what is under it, so a shadow
  /// drawn beneath the body would darken the menu itself (the "dull" look next to a native menu).
  private let shadowClip = CALayer()
  private let shadowClipMask = CAShapeLayer()
  private let shadowLayer = CALayer()
  private let rim = CALayer()
  private var material: NSView!
  private let margin: CGFloat
  private let radius: CGFloat
  private let usesGlass: Bool

  init(margin: CGFloat, radius: CGFloat, material kind: ContextMenuMaterial) {
    self.margin = margin
    self.radius = radius
    usesGlass = {
      switch kind {
      case .glass: return true
      case .vibrancy: return false
      case .automatic:
        if #available(macOS 26.0, *) { return true }
        return false
      }
    }()
    super.init(frame: .zero)
    wantsLayer = true
    layer?.masksToBounds = false

    shadowLayer.shadowColor = NSColor.black.cgColor
    shadowLayer.backgroundColor = NSColor.black.cgColor
    shadowClipMask.fillRule = .evenOdd
    shadowClip.mask = shadowClipMask
    shadowClip.addSublayer(shadowLayer)
    layer?.addSublayer(shadowClip)

    if usesGlass, #available(macOS 26.0, *) {
      let glass = NSGlassEffectView()
      glass.cornerRadius = radius
      glass.style = .regular
      Self.applyMenuGlass(to: glass)
      glass.contentView = contentContainer
      material = glass
    } else {
      let effect = NSVisualEffectView()
      effect.material = .menu
      effect.blendingMode = .behindWindow
      effect.state = .active
      effect.wantsLayer = true
      effect.layer?.cornerRadius = radius
      effect.layer?.cornerCurve = .continuous
      effect.layer?.masksToBounds = true
      effect.addSubview(contentContainer)
      material = effect
    }
    addSubview(material)

    rim.cornerRadius = radius
    rim.cornerCurve = .continuous
    layer?.addSublayer(rim)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  /// The settings AppKit's own menu window puts on its glass (read from `NSPopupMenuWindow.glassView` on
  /// macOS 27): the "menu" subvariant is brighter and more frosted than a default glass view, which looks
  /// dull and tinted next to a real menu. These are private keys, so each is set only when the view
  /// answers its setter; on a system without them the public `.regular` glass stays.
  @available(macOS 26.0, *)
  static func applyMenuGlass(to glass: NSGlassEffectView) {
    let settings: [(String, Any)] = [
      ("_variant", 0),
      ("_subvariant", "menu"),
      ("_adaptiveAppearance", 1),
      ("_effectInteractiveVariantName", "menu"),
    ]
    for (key, value) in settings where glass.responds(to: NSSelectorFromString("set\(key):")) {
      glass.setValue(value, forKey: key)
    }
  }

  override func layout() {
    super.layout()
    let body = bounds.insetBy(dx: margin, dy: margin)
    material.frame = body
    contentContainer.frame = material is NSVisualEffectView ? material.bounds : contentContainer.frame
    let dark = effectiveAppearance.isDark
    let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    shadowClip.frame = bounds
    let bodyPath = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)
    let clip = CGMutablePath()
    clip.addRect(bounds)
    clip.addPath(bodyPath)
    shadowClipMask.frame = bounds
    shadowClipMask.path = clip
    shadowLayer.frame = body
    shadowLayer.cornerRadius = radius
    shadowLayer.cornerCurve = .continuous
    shadowLayer.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: body.size), cornerWidth: radius, cornerHeight: radius, transform: nil)
    // A soft, wide shadow like the menu window's, a little deeper in dark mode where it reads less.
    shadowLayer.shadowOpacity = dark ? 0.32 : 0.16
    shadowLayer.shadowRadius = 16
    shadowLayer.shadowOffset = CGSize(width: 0, height: -6)
    rim.frame = body
    // Glass draws its own edge; the rim is for the vibrancy fallback and for Increase Contrast.
    if increaseContrast {
      rim.borderWidth = 1
      rim.borderColor = (dark ? NSColor.white.withAlphaComponent(0.45) : NSColor.black.withAlphaComponent(0.45)).cgColor
    } else if usesGlass {
      rim.borderWidth = 0
    } else {
      rim.borderWidth = 0.5
      rim.borderColor = (dark ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.12)).cgColor
    }
    CATransaction.commit()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsLayout = true
  }

  /// The visible body in this view's coordinates.
  var bodyRect: NSRect { bounds.insetBy(dx: margin, dy: margin) }
}

extension NSAppearance {
  var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

// MARK: - Menu content

/// A menu's rows. Text, separators and shortcuts are drawn by one view; the highlight is its own layer
/// below them (AppKit's recipe: accent at 75% plus a soft-light accent tint), and icons are image views
/// so they tint like AppKit's and can play symbol effects.
final class ContextMenuContentView: NSView {
  let shownMenu: NSMenu
  let metrics: ContextMenuMetrics
  var defaultIconEffect: ContextMenuIconEffect = .bounceUp
  private(set) var rows: [MenuRow] = []
  private(set) var rowFrames: [NSRect] = []
  private var accessibilityRows: [ContextMenuRowElement] = []
  private let highlightView = ContextMenuHighlightView()
  private lazy var textView = ContextMenuRowsView(owner: self)
  private var iconViews: [Int: NSImageView] = [:]

  var highlightedIndex: Int? {
    didSet {
      guard oldValue != highlightedIndex else { return }
      updateHighlight()
      textView.needsDisplay = true
      for index in [oldValue, highlightedIndex].compactMap({ $0 }) {
        updateIconTint(index)
      }
      if let highlightedIndex, let element = accessibilityElement(forRow: highlightedIndex) {
        NSAccessibility.post(element: element, notification: .focusedUIElementChanged)
        NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
      }
    }
  }

  /// Set by the session; activates a row from accessibility.
  var onAccessibilityPress: ((Int) -> Void)?
  /// Set by the session; the submenu surface's content for a row, when one is open.
  var openSubmenuContent: ((Int) -> ContextMenuContentView?)?

  fileprivate(set) var hasState = false
  fileprivate(set) var hasImages = false

  init(menu: NSMenu, metrics: ContextMenuMetrics) {
    self.shownMenu = menu
    self.metrics = metrics
    super.init(frame: .zero)
    addSubview(highlightView)
    addSubview(textView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  /// Rebuilds rows for the held modifier keys. Returns the size the content wants.
  @discardableResult
  func reload(modifiers: NSEvent.ModifierFlags) -> NSSize {
    let previous = highlightedIndex.flatMap { rows.indices.contains($0) ? rows[$0].item : nil }
    let previousBase = previous.flatMap { baseItem(of: $0) }
    for row in rows where row.kind == .view {
      row.item.view?.removeFromSuperview()
    }
    rows = MenuModel.rows(for: shownMenu, modifiers: modifiers)
    hasState = rows.contains { $0.kind == .item && $0.item.state != .off }
    hasImages = rows.contains { $0.kind == .item && $0.item.image != nil && $0.item.contextMenuStyle != .footnote }

    let width = measureWidth()
    var y = metrics.verticalPadding
    rowFrames = rows.map { row in
      let height: CGFloat
      switch row.kind {
      case .separator: height = metrics.separatorHeight
      case .header: height = metrics.headerHeight
      case .view: height = row.item.view?.frame.height ?? 0
      case .item:
        if row.item.contextMenuStyle == .footnote {
          height = metrics.footnoteRowHeight
        } else {
          height = (row.item.subtitle?.isEmpty == false) ? metrics.subtitleRowHeight : metrics.rowHeight
        }
      }
      let frame = NSRect(x: 0, y: y, width: width, height: height)
      y += height
      return frame
    }
    for (index, row) in rows.enumerated() where row.kind == .view {
      guard let view = row.item.view else { continue }
      view.removeFromSuperview()
      view.frame = NSRect(x: 0, y: rowFrames[index].minY, width: max(view.frame.width, width), height: view.frame.height)
      addSubview(view)
    }
    let size = NSSize(width: width, height: y + metrics.verticalPadding)
    setFrameSize(size)
    textView.frame = bounds
    rebuildIcons()
    rebuildAccessibility()

    // Keep the highlight on the same logical item when an alternate swaps in.
    if let previousBase {
      highlightedIndex = rows.firstIndex { baseItem(of: $0.item) === previousBase }
    }
    updateHighlight()
    textView.needsDisplay = true
    return size
  }

  /// Alternates belong to the item they fold into.
  private func baseItem(of item: NSMenuItem) -> NSMenuItem {
    guard item.isAlternate, let menu = item.menu else { return item }
    var index = menu.index(of: item)
    while index > 0, menu.items[index].isAlternate {
      index -= 1
    }
    return menu.items[index]
  }

  func rowIndex(at point: NSPoint) -> Int? {
    rowFrames.firstIndex { $0.contains(point) }
  }

  // MARK: Layout

  var titleFont: NSFont { NSFont.menuFont(ofSize: 0) }
  /// AppKit draws shortcuts in the keyboard font (`.Keyboard`), whose modifier glyphs are drawn for menus.
  let shortcutFont: NSFont = CTFontCreateUIFontForLanguage(.menuItemCmdKey, 13, nil) as NSFont? ?? NSFont.menuFont(ofSize: 0)
  var headerFont: NSFont { NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold) }
  var subtitleFont: NSFont { NSFont.systemFont(ofSize: NSFont.smallSystemFontSize) }
  var footnoteFont: NSFont { NSFont.systemFont(ofSize: NSFont.smallSystemFontSize) }

  var leadingColumns: CGFloat {
    var x = metrics.highlightInset + metrics.contentPadding
    if hasState { x += metrics.stateColumnWidth }
    if hasImages { x += metrics.iconColumnWidth + metrics.iconGap }
    return x
  }

  private func measureWidth() -> CGFloat {
    var width = metrics.minWidth
    for row in rows {
      switch row.kind {
      case .item:
        let item = row.item
        if item.contextMenuStyle == .footnote {
          let w = metrics.highlightInset + metrics.contentPadding + (item.title as NSString).size(withAttributes: [.font: footnoteFont]).width + metrics.contentPadding + metrics.highlightInset
          width = max(width, w)
          continue
        }
        var w = leadingColumns + CGFloat(item.indentationLevel) * 10
        w += titleString(item, highlighted: false).size().width
        if let subtitle = item.subtitle, !subtitle.isEmpty {
          w = max(w, leadingColumns + (subtitle as NSString).size(withAttributes: [.font: subtitleFont]).width)
        }
        let (modifierText, keyText) = MenuModel.keyEquivalentParts(for: item)
        if item.submenu != nil {
          w += metrics.shortcutGap + 10
        } else if !keyText.isEmpty {
          let keyWidth = max(metrics.keyColumnWidth, (keyText as NSString).size(withAttributes: [.font: shortcutFont]).width)
          w += metrics.shortcutGap + keyWidth + 3 + (modifierText as NSString).size(withAttributes: [.font: shortcutFont]).width
        }
        if let badge = item.badge?.stringValue, !badge.isEmpty {
          w += 8 + (badge as NSString).size(withAttributes: [.font: subtitleFont]).width + 12
        }
        w += metrics.contentPadding + metrics.highlightInset
        width = max(width, w)
      case .header:
        let w = leadingColumns + (row.item.title as NSString).size(withAttributes: [.font: headerFont]).width + metrics.contentPadding + metrics.highlightInset
        width = max(width, w)
      case .view:
        width = max(width, row.item.view?.frame.width ?? 0)
      case .separator:
        break
      }
    }
    return ceil(min(width, metrics.maxWidth))
  }

  // MARK: Colors

  /// AppKit's colors: label, tertiary label when disabled (title, icon and shortcut alike), white on the highlight.
  func foreground(for item: NSMenuItem, highlighted: Bool) -> NSColor {
    if !item.isEnabled { return .tertiaryLabelColor }
    if highlighted { return .selectedMenuItemTextColor }
    return item.contextMenuStyle == .destructive ? .systemRed : .labelColor
  }

  func shortcutColor(for item: NSMenuItem, highlighted: Bool) -> NSColor {
    if highlighted && item.isEnabled { return .selectedMenuItemTextColor }
    return .tertiaryLabelColor
  }

  func titleString(_ item: NSMenuItem, highlighted: Bool) -> NSAttributedString {
    if let attributed = item.attributedTitle, attributed.length > 0 {
      guard highlighted else { return attributed }
      let copy = NSMutableAttributedString(attributedString: attributed)
      copy.addAttribute(.foregroundColor, value: NSColor.selectedMenuItemTextColor, range: NSRange(location: 0, length: copy.length))
      return copy
    }
    return NSAttributedString(string: item.title, attributes: [
      .font: titleFont,
      .foregroundColor: foreground(for: item, highlighted: highlighted),
    ])
  }

  func isHighlighted(_ index: Int) -> Bool {
    index == highlightedIndex && rows.indices.contains(index) && rows[index].isSelectable
  }

  // MARK: Highlight

  private func updateHighlight() {
    guard let index = highlightedIndex, rows.indices.contains(index), rows[index].isSelectable else {
      highlightView.isHidden = true
      return
    }
    let destructive = rows[index].item.contextMenuStyle == .destructive
    highlightView.color = destructive ? .systemRed : .controlAccentColor
    highlightView.radius = metrics.highlightRadius
    highlightView.frame = rowFrames[index].insetBy(dx: metrics.highlightInset, dy: 0)
    highlightView.isHidden = false
  }

  // MARK: Icons

  private func iconFrame(forRow index: Int) -> NSRect {
    let frame = rowFrames[index]
    let item = rows[index].item
    var x = metrics.highlightInset + metrics.contentPadding + CGFloat(item.indentationLevel) * 10
    if hasState { x += metrics.stateColumnWidth }
    let centerY = (item.subtitle?.isEmpty == false) ? frame.minY + metrics.rowHeight / 2 + 1 : frame.midY
    let side = max(metrics.iconColumnWidth, metrics.rowHeight - 6)
    return NSRect(x: x + (metrics.iconColumnWidth - side) / 2, y: centerY - side / 2, width: side, height: side)
  }

  private func rebuildIcons() {
    iconViews.values.forEach { $0.removeFromSuperview() }
    iconViews = [:]
    guard hasImages else { return }
    let configuration = NSImage.SymbolConfiguration(pointSize: metrics.iconPointSize, weight: metrics.iconWeight, scale: metrics.iconScale)
    for (index, row) in rows.enumerated() where row.kind == .item && row.item.contextMenuStyle != .footnote {
      guard let image = row.item.image else { continue }
      let view = NSImageView(frame: iconFrame(forRow: index))
      // Symbols draw at their natural size for the menu font, as AppKit's menu does; no scaling up.
      view.image = image.isTemplate ? (image.withSymbolConfiguration(configuration) ?? image) : image
      view.imageScaling = .scaleProportionallyDown
      view.imageAlignment = .alignCenter
      view.isEditable = false
      view.setAccessibilityElement(false)
      addSubview(view, positioned: .above, relativeTo: textView)
      iconViews[index] = view
      updateIconTint(index)
    }
  }

  private func updateIconTint(_ index: Int) {
    guard let view = iconViews[index], rows.indices.contains(index) else { return }
    view.contentTintColor = foreground(for: rows[index].item, highlighted: isHighlighted(index))
  }

  /// Plays the item's icon effect once. Called by the session when a highlight lands on a row.
  func playIconEffect(row index: Int) {
    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
          let view = iconViews[index], rows.indices.contains(index), view.image?.isTemplate == true
    else { return }
    let effect = rows[index].item.contextMenuIconEffect ?? defaultIconEffect
    view.removeAllSymbolEffects(animated: false)
    switch effect {
    case .none: break
    case .bounceUp: view.addSymbolEffect(.bounce.up, options: .nonRepeating)
    case .bounceDown: view.addSymbolEffect(.bounce.down, options: .nonRepeating)
    case .wiggleLeft: view.addSymbolEffect(.wiggle.left, options: .nonRepeating)
    case .wiggleRight: view.addSymbolEffect(.wiggle.right, options: .nonRepeating)
    case .wiggleClockwise: view.addSymbolEffect(.wiggle.clockwise, options: .nonRepeating)
    case .wiggleForward: view.addSymbolEffect(.wiggle.forward, options: .nonRepeating)
    case .rotate: view.addSymbolEffect(.rotate.clockwise, options: .nonRepeating)
    }
    iconEffectsPlayed += 1
  }

  /// For tests.
  private(set) var iconEffectsPlayed = 0
  var iconViewCount: Int { iconViews.count }
  func iconTint(row index: Int) -> NSColor? { iconViews[index]?.contentTintColor }

  // MARK: Accessibility

  private func rebuildAccessibility() {
    accessibilityRows = rows.enumerated().compactMap { index, row in
      guard row.kind == .item, row.item.contextMenuStyle != .footnote else { return nil }
      return ContextMenuRowElement(index: index, item: row.item, parent: self)
    }
  }

  func accessibilityElement(forRow index: Int) -> ContextMenuRowElement? {
    accessibilityRows.first { $0.index == index }
  }

  override func isAccessibilityElement() -> Bool { true }
  override func accessibilityRole() -> NSAccessibility.Role? { .menu }
  override func accessibilityChildren() -> [Any]? {
    var children: [Any] = accessibilityRows
    for row in rows where row.kind == .view {
      if let view = row.item.view { children.append(view) }
    }
    return children
  }

  override func accessibilitySelectedChildren() -> [Any]? {
    highlightedIndex.flatMap { accessibilityElement(forRow: $0) }.map { [$0] }
  }
}

/// The highlight. AppKit's selection material is a monochrome, accent-tinted backdrop under an accent
/// soft-light tint and an accent fill at 75%. The backdrop filter is private, so a dimmed accent base
/// stands in for it; the result measures within a few levels of AppKit's on the same background.
final class ContextMenuHighlightView: NSView {
  private let base = CALayer()
  private let tint = CALayer()
  private let fill = CALayer()
  var color: NSColor = .controlAccentColor { didSet { needsLayout = true } }
  var radius: CGFloat = 8 { didSet { needsLayout = true } }
  /// Lab only: picks a recipe by number to compare against AppKit.
  nonisolated(unsafe) static var recipe = Int(ProcessInfo.processInfo.environment["CONTEXT_MENU_HIGHLIGHT"] ?? "") ?? 0

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    tint.compositingFilter = "softLightBlendMode"
    layer?.addSublayer(base)
    layer?.addSublayer(tint)
    layer?.addSublayer(fill)
    isHidden = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    var accent = color.cgColor
    var dimmed = color.cgColor
    effectiveAppearance.performAsCurrentDrawingAppearance {
      accent = color.cgColor
      // AppKit's backdrop is darker in dark mode (measured #008AEB light, #0476D7 dark on a white window).
      dimmed = (color.blended(withFraction: effectiveAppearance.isDark ? 0.45 : 0.12, of: .black) ?? color).cgColor
    }
    switch Self.recipe {
    case 1: // AppKit's layers without the backdrop.
      base.opacity = 0; tint.opacity = 1; fill.opacity = 0.75
    case 2: // Solid accent.
      base.opacity = 1; tint.opacity = 0; fill.opacity = 0
    case 3: // Accent base, soft-light tint, accent at 75%.
      base.opacity = 1; tint.opacity = 1; fill.opacity = 0.75
    default: // Dimmed accent base, accent at 75% over it: closest to AppKit's.
      base.opacity = 1; tint.opacity = 0; fill.opacity = 0.75
    }
    for sub in [base, tint, fill] {
      sub.frame = bounds
      sub.cornerRadius = radius
      sub.cornerCurve = .continuous
      sub.backgroundColor = accent
    }
    if Self.recipe == 0 { base.backgroundColor = dimmed }
    CATransaction.commit()
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    needsLayout = true
  }
}

/// Draws the text, separators, headers, state marks, chevrons and shortcuts of a content view.
final class ContextMenuRowsView: NSView {
  private unowned let owner: ContextMenuContentView

  init(owner: ContextMenuContentView) {
    self.owner = owner
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func isAccessibilityElement() -> Bool { false }

  override func draw(_ dirtyRect: NSRect) {
    let metrics = owner.metrics
    for (index, row) in owner.rows.enumerated() {
      let frame = owner.rowFrames[index]
      guard frame.intersects(dirtyRect) else { continue }
      switch row.kind {
      case .separator:
        let inset = metrics.highlightInset + metrics.contentPadding
        let line = NSRect(x: inset, y: frame.midY - 0.5, width: frame.width - 2 * inset, height: 1)
        NSColor.separatorColor.setFill()
        line.fill()
      case .header:
        let text = NSAttributedString(string: row.item.title, attributes: [.font: owner.headerFont, .foregroundColor: NSColor.secondaryLabelColor])
        let size = text.size()
        text.draw(at: NSPoint(x: metrics.highlightInset + metrics.contentPadding, y: frame.midY - size.height / 2))
      case .view:
        break
      case .item:
        if row.item.contextMenuStyle == .footnote {
          drawFootnote(row.item, in: frame)
        } else {
          drawItem(row.item, in: frame, highlighted: owner.isHighlighted(index))
        }
      }
    }
  }

  private func drawFootnote(_ item: NSMenuItem, in frame: NSRect) {
    let metrics = owner.metrics
    let text = NSAttributedString(string: item.title, attributes: [.font: owner.footnoteFont, .foregroundColor: NSColor.secondaryLabelColor])
    let size = text.size()
    let x = metrics.highlightInset + metrics.contentPadding
    text.draw(with: NSRect(x: x, y: frame.midY - size.height / 2, width: frame.width - 2 * x, height: size.height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
  }

  private func drawItem(_ item: NSMenuItem, in frame: NSRect, highlighted: Bool) {
    let metrics = owner.metrics
    let color = owner.foreground(for: item, highlighted: highlighted)
    let hasSubtitle = item.subtitle?.isEmpty == false
    let titleCenterY = hasSubtitle ? frame.minY + metrics.rowHeight / 2 + 1 : frame.midY
    var x = metrics.highlightInset + metrics.contentPadding + CGFloat(item.indentationLevel) * 10

    if owner.hasState {
      let image: NSImage? = switch item.state {
      case .on: item.onStateImage ?? NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
      case .mixed: item.mixedStateImage ?? NSImage(systemSymbolName: "minus", accessibilityDescription: nil)
      default: item.offStateImage
      }
      if let image = image?.withSymbolConfiguration(.init(pointSize: 11, weight: .semibold)) ?? image {
        draw(image, centeredIn: NSRect(x: x, y: titleCenterY - 7, width: 12, height: 14), color: color)
      }
      x += metrics.stateColumnWidth
    }
    if owner.hasImages {
      x += metrics.iconColumnWidth + metrics.iconGap
    }

    let title = owner.titleString(item, highlighted: highlighted)
    let titleSize = title.size()
    let trailingLimit = frame.maxX - metrics.highlightInset - metrics.contentPadding
    var titleLimit = trailingLimit

    if item.submenu != nil {
      if let chevron = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold)) {
        draw(chevron, centeredIn: NSRect(x: trailingLimit - 10, y: titleCenterY - 6, width: 10, height: 12), color: highlighted ? color : .tertiaryLabelColor)
      }
      titleLimit = trailingLimit - 18
    } else {
      let (modifierText, keyText) = MenuModel.keyEquivalentParts(for: item)
      if !keyText.isEmpty {
        let attributes: [NSAttributedString.Key: Any] = [.font: owner.shortcutFont, .foregroundColor: owner.shortcutColor(for: item, highlighted: highlighted)]
        let key = NSAttributedString(string: keyText, attributes: attributes)
        let keySize = key.size()
        // AppKit right-aligns the key and ends the modifiers where the key column starts: ⌘R, ⌘⌫.
        let keyX = trailingLimit - keySize.width
        key.draw(at: NSPoint(x: keyX, y: titleCenterY - keySize.height / 2))
        let modifiers = NSAttributedString(string: modifierText, attributes: attributes)
        let modifierSize = modifiers.size()
        let modifierX = min(keyX - 1, trailingLimit - metrics.keyColumnWidth) - modifierSize.width
        modifiers.draw(at: NSPoint(x: modifierX, y: titleCenterY - modifierSize.height / 2))
        titleLimit = modifierX - 12
      }
    }

    if let badge = item.badge?.stringValue, !badge.isEmpty {
      let text = NSAttributedString(string: badge, attributes: [.font: owner.subtitleFont, .foregroundColor: highlighted ? NSColor.selectedMenuItemTextColor : NSColor.secondaryLabelColor])
      let size = text.size()
      let capsule = NSRect(x: titleLimit - size.width - 12, y: titleCenterY - 8, width: size.width + 12, height: 16)
      (highlighted ? NSColor.white.withAlphaComponent(0.25) : NSColor.quaternaryLabelColor).setFill()
      NSBezierPath(roundedRect: capsule, xRadius: 8, yRadius: 8).fill()
      text.draw(at: NSPoint(x: capsule.minX + 6, y: titleCenterY - size.height / 2))
      titleLimit = capsule.minX - 6
    }

    title.draw(with: NSRect(x: x, y: titleCenterY - titleSize.height / 2, width: max(0, titleLimit - x), height: titleSize.height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])

    if hasSubtitle, let subtitle = item.subtitle {
      let sub = NSAttributedString(string: subtitle, attributes: [
        .font: owner.subtitleFont,
        .foregroundColor: highlighted ? NSColor.selectedMenuItemTextColor.withAlphaComponent(0.8) : NSColor.secondaryLabelColor,
      ])
      sub.draw(with: NSRect(x: x, y: titleCenterY + titleSize.height / 2 - 1, width: max(0, trailingLimit - x), height: 16), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
  }

  private func draw(_ image: NSImage, centeredIn rect: NSRect, color: NSColor) {
    let size = image.size
    guard size.width > 0, size.height > 0 else { return }
    let scale = min(rect.width / size.width, rect.height / size.height, 1)
    let drawSize = NSSize(width: size.width * scale, height: size.height * scale)
    let drawRect = NSRect(x: rect.midX - drawSize.width / 2, y: rect.midY - drawSize.height / 2, width: drawSize.width, height: drawSize.height)
    guard image.isTemplate else {
      image.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
      return
    }
    let tinted = NSImage(size: drawSize, flipped: false) { bounds in
      image.draw(in: bounds)
      color.set()
      bounds.fill(using: .sourceAtop)
      return true
    }
    tinted.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
  }
}

/// A menu row as VoiceOver sees it: title, enabled state, shortcut, check mark and submenu, as AppKit
/// reports them for its own menu items.
final class ContextMenuRowElement: NSAccessibilityElement {
  let index: Int
  weak var item: NSMenuItem?
  weak var parentView: ContextMenuContentView?

  init(index: Int, item: NSMenuItem, parent: ContextMenuContentView) {
    self.index = index
    self.item = item
    self.parentView = parent
    super.init()
    setAccessibilityParent(parent)
    setAccessibilityRole(.menuItem)
    let title = item.attributedTitle?.string ?? item.title
    setAccessibilityTitle(title)
    setAccessibilityLabel(title)
    setAccessibilityEnabled(item.isEnabled)
    if let help = item.toolTip { setAccessibilityHelp(help) }
  }

  override func accessibilityFrame() -> NSRect {
    guard let parentView, let window = parentView.window, parentView.rowFrames.indices.contains(index) else { return .zero }
    return window.convertToScreen(parentView.convert(parentView.rowFrames[index], to: nil))
  }

  override func accessibilityPerformPress() -> Bool {
    guard item?.isEnabled == true else { return false }
    parentView?.onAccessibilityPress?(index)
    return true
  }

  override func accessibilityPerformPick() -> Bool { accessibilityPerformPress() }

  override func isAccessibilitySelected() -> Bool {
    parentView?.highlightedIndex == index
  }

  override func accessibilityValue() -> Any? {
    guard let item else { return nil }
    if let subtitle = item.subtitle, !subtitle.isEmpty { return subtitle }
    return nil
  }

  override func accessibilityChildren() -> [Any]? {
    // An open submenu hangs under its item, as AppKit's AXMenuItem → AXMenu.
    parentView?.openSubmenuContent?(index).map { [$0] }
  }

  // Shortcut and mark attributes have no modern setters; VoiceOver reads them through the attribute API.
  private static let cmdChar = "AXMenuItemCmdChar"
  private static let cmdModifiers = "AXMenuItemCmdModifiers"
  private static let cmdVirtualKey = "AXMenuItemCmdVirtualKey"
  private static let markChar = "AXMenuItemMarkChar"

  override func accessibilityAttributeNames() -> [NSAccessibility.Attribute] {
    super.accessibilityAttributeNames() + [Self.cmdChar, Self.cmdModifiers, Self.markChar].map(NSAccessibility.Attribute.init(rawValue:))
  }

  override func accessibilityAttributeValue(_ attribute: NSAccessibility.Attribute) -> Any? {
    guard let item else { return super.accessibilityAttributeValue(attribute) }
    switch attribute.rawValue {
    case Self.cmdChar:
      guard !item.keyEquivalent.isEmpty else { return nil }
      return MenuModel.keyEquivalentParts(for: item).1
    case Self.cmdModifiers:
      guard !item.keyEquivalent.isEmpty else { return nil }
      // kAXMenuItemModifierNoCommand = 8, shift = 1, option = 2, control = 4.
      let mask = item.keyEquivalentModifierMask
      var value = 0
      if mask.contains(.shift) || (item.keyEquivalent.count == 1 && item.keyEquivalent != item.keyEquivalent.lowercased()) { value |= 1 }
      if mask.contains(.option) { value |= 2 }
      if mask.contains(.control) { value |= 4 }
      if !mask.contains(.command) { value |= 8 }
      return value
    case Self.markChar:
      return item.state == .on ? "✓" : (item.state == .mixed ? "-" : nil)
    default:
      return super.accessibilityAttributeValue(attribute)
    }
  }
}

// MARK: - Surface

/// One floating menu (root or submenu): a panel, its chrome and its rows.
@MainActor
final class ContextMenuSurface {
  let menu: NSMenu
  let panel = ContextMenuPanelPool.take()
  let chrome: ContextMenuChromeView
  let content: ContextMenuContentView
  let scrollView = NSScrollView()
  let metrics: ContextMenuMetrics
  /// Row index in the parent surface that opened this submenu.
  let parentRowIndex: Int?

  init(menu: NSMenu, metrics: ContextMenuMetrics, material: ContextMenuMaterial, parentRowIndex: Int?, appearance: NSAppearance?) {
    self.menu = menu
    self.metrics = metrics
    self.parentRowIndex = parentRowIndex
    chrome = ContextMenuChromeView(margin: metrics.shadowMargin, radius: metrics.cornerRadius, material: material)
    content = ContextMenuContentView(menu: menu, metrics: metrics)
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = false
    scrollView.verticalScrollElasticity = .none
    scrollView.documentView = content
    chrome.contentContainer.addSubview(scrollView)
    panel.contentView = chrome
    panel.appearance = appearance
  }

  /// Lays the surface out for a body size capped to `maxHeight`, and returns the body size.
  @discardableResult
  func reload(modifiers: NSEvent.ModifierFlags, maxHeight: CGFloat) -> NSSize {
    let size = content.reload(modifiers: modifiers)
    let body = NSSize(width: size.width, height: min(size.height, maxHeight))
    let margin = metrics.shadowMargin
    let origin = panel.frame.origin
    // Keep the top edge where it was when a modifier change resizes an open menu.
    let top = panel.frame.maxY
    panel.setContentSize(NSSize(width: body.width + 2 * margin, height: body.height + 2 * margin))
    if panel.isVisible {
      panel.setFrameOrigin(NSPoint(x: origin.x, y: top - panel.frame.height))
    }
    chrome.frame = NSRect(origin: .zero, size: panel.frame.size)
    chrome.contentContainer.frame = NSRect(origin: .zero, size: body)
    scrollView.frame = NSRect(origin: .zero, size: body)
    chrome.layoutSubtreeIfNeeded()
    return body
  }

  /// The visible body on screen.
  var bodyScreenFrame: NSRect {
    panel.frame.insetBy(dx: metrics.shadowMargin, dy: metrics.shadowMargin)
  }

  func setBodyOrigin(_ origin: NSPoint) {
    panel.setFrameOrigin(NSPoint(x: origin.x - metrics.shadowMargin, y: origin.y - metrics.shadowMargin))
  }

  func rowIndex(atScreen point: NSPoint) -> Int? {
    guard bodyScreenFrame.contains(point) else { return nil }
    let windowPoint = panel.convertPoint(fromScreen: point)
    return content.rowIndex(at: content.convert(windowPoint, from: nil))
  }

  func rowScreenFrame(_ index: Int) -> NSRect {
    panel.convertToScreen(content.convert(content.rowFrames[index], to: nil))
  }

  func scrollToVisible(_ index: Int) {
    content.scrollToVisible(content.rowFrames[index])
  }
}
