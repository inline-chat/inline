import UIKit

/// The menu's actions, drawn like the platform menu from a `UIMenu`. Inline menus become
/// sections, other menus open as pages behind a back row, and rows run their actions through
/// `UIControl.sendAction`, so the chat's one menu builder serves both menus.
///
/// Each menu level is a page laid out at its own size. Opening one slides it in while the
/// container springs to its size, Telegram style; a page that gets new rows keeps the rows it
/// already shows and only moves them, so changing the menu never redraws it.
///
/// Touches anywhere on the menu highlight the row under the finger and pick it on lift; the
/// host forwards the opening hold's finger the same way, so a press can slide onto an action.
final class MessageContextMenuActionsView: UIView, UIGestureRecognizerDelegate {
  enum Element {
    case action(UIAction)
    case submenu(UIMenu)
    /// The header of an opened submenu; picking it goes back.
    case back(UIMenu)
  }

  /// A row was picked by tap, drag-release or VoiceOver.
  var onSelect: ((MessageContextMenuRowView) -> Void)?
  /// The menu is about to take a new size. The host lays its frame out inside this call, which
  /// runs inside the menu's animation, so the container and its rows move on one spring.
  var onLayoutChange: (() -> Void)?

  let style: MessageContextMenuStyle
  var motion = MessageContextMenuMotion.standard
  private let platter: UIVisualEffectView
  /// Clips sliding pages to the platter's shape without clipping the glass itself.
  private let clipView = UIView()
  private var rootMenu: UIMenu
  private var leadingActions: [UIAction] = []
  private var pages: [MessageContextMenuPageView] = []
  /// The widest a page may be, from the room the host last offered.
  private var maximumWidth: CGFloat
  private let selectionFeedback = UISelectionFeedbackGenerator()
  private lazy var tracker: UILongPressGestureRecognizer = {
    let gesture = UILongPressGestureRecognizer(target: self, action: #selector(handleTracking(_:)))
    gesture.minimumPressDuration = 0
    gesture.allowableMovement = .greatestFiniteMagnitude
    gesture.cancelsTouchesInView = false
    gesture.delegate = self
    return gesture
  }()

  init(menu: UIMenu, style: MessageContextMenuStyle) {
    rootMenu = menu
    self.style = style
    maximumWidth = style.maximumWidth
    platter = style.makePlatter()
    super.init(frame: .zero)
    addSubview(platter)
    clipView.clipsToBounds = true
    clipView.layer.cornerRadius = style.cornerRadius
    clipView.layer.cornerCurve = .continuous
    platter.contentView.addSubview(clipView)
    // On the platter so its touches also reach the interactive glass.
    platter.addGestureRecognizer(tracker)
    let root = makePage(menu: nil)
    pages = [root]
    clipView.addSubview(root)
    accessibilityContainerType = .list
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  var firstRow: UIView? { topPage.rows.first }
  private var topPage: MessageContextMenuPageView { pages[pages.count - 1] }

  /// Replaces the menu and the actions shown above it. Rows the menu already shows stay and
  /// move; an open submenu closes.
  func setMenu(_ menu: UIMenu, leadingActions: [UIAction], animated: Bool) {
    rootMenu = menu
    self.leadingActions = leadingActions
    let root = pages[0]
    let fades = animated && pages.count == 1
    root.setSections(rootSections(), animated: fades)
    if pages.count > 1 {
      popToRoot(animated: animated)
    } else {
      transition(animated: animated, {}, completion: {})
      root.runFades(animated: fades && canAnimate, timeScale: timeScale)
    }
  }

  func open(_ submenu: UIMenu) {
    let previous = topPage
    let page = makePage(menu: submenu)
    pages.append(page)
    clipView.addSubview(page)
    let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
    let width = max(bounds.width, 1)
    page.frame = CGRect(origin: CGPoint(x: isRTL ? -width * 0.3 : width * 0.3, y: 0), size: page.size)
    page.alpha = 0
    previous.highlightRow(nil)
    transition(animated: true) {
      page.frame.origin.x = 0
      previous.frame.origin.x = isRTL ? page.size.width * 0.15 : -page.size.width * 0.15
    } completion: {
      previous.isHidden = true
    }
    crossFade(out: previous, in: page)
    UIAccessibility.post(notification: .layoutChanged, argument: page.rows.first)
  }

  func goBack() {
    guard pages.count > 1 else { return }
    let leaving = pages.removeLast()
    reveal(topPage, replacing: leaving, animated: true)
  }

  private func popToRoot(animated: Bool) {
    guard pages.count > 1 else { return }
    let leaving = pages.removeLast()
    pages[1...].forEach { $0.removeFromSuperview() }
    pages.removeSubrange(1...)
    reveal(pages[0], replacing: leaving, animated: animated)
  }

  private func reveal(_ page: MessageContextMenuPageView, replacing leaving: MessageContextMenuPageView, animated: Bool) {
    let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
    page.isHidden = false
    leaving.highlightRow(nil)
    transition(animated: animated) {
      page.frame = CGRect(origin: .zero, size: page.size)
      leaving.frame.origin.x = isRTL ? -leaving.size.width * 0.3 : leaving.size.width * 0.3
    } completion: {
      leaving.removeFromSuperview()
      page.finishTransition()
    }
    if animated {
      crossFade(out: leaving, in: page)
    } else {
      leaving.alpha = 0
      page.alpha = 1
    }
    UIAccessibility.post(notification: .layoutChanged, argument: page.rows.first)
  }

  private var canAnimate: Bool { window != nil && !UIAccessibility.isReduceMotionEnabled }

  /// The page spring's length relative to Telegram's 0.45 s, for the fades that ride with it.
  private var timeScale: Double { motion.pageSpringDuration / 0.45 }

  /// The outgoing page fades out over the first part of the move and the incoming one fades in
  /// after it, so the two never show their text over each other.
  private func crossFade(out outgoing: UIView, in incoming: UIView) {
    guard canAnimate else {
      outgoing.alpha = 0
      incoming.alpha = 1
      return
    }
    UIView.animate(withDuration: 0.12 * timeScale, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
      outgoing.alpha = 0
    }
    UIView.animate(withDuration: 0.22 * timeScale, delay: 0.1 * timeScale, options: [.curveEaseIn, .beginFromCurrentState]) {
      incoming.alpha = 1
    }
  }

  /// Runs `changes` with the host's new layout on the page spring, or at once without motion.
  private func transition(animated: Bool, _ changes: @escaping () -> Void, completion: @escaping () -> Void) {
    let apply = { [self] in
      onLayoutChange?()
      changes()
      layoutIfNeeded()
    }
    guard animated, canAnimate else {
      UIView.performWithoutAnimation(apply)
      completion()
      return
    }
    UIView.animate(
      springDuration: motion.pageSpringDuration,
      bounce: 0,
      initialSpringVelocity: 0,
      delay: 0,
      options: [.beginFromCurrentState, .allowUserInteraction],
      animations: apply,
      completion: { _ in completion() }
    )
  }

  private func makePage(menu: UIMenu?) -> MessageContextMenuPageView {
    let page = MessageContextMenuPageView(style: style, maximumWidth: maximumWidth)
    page.onActivate = { [weak self] row in self?.onSelect?(row) }
    page.setSections(menu.map { [[.back($0)]] + Self.sections(of: $0) } ?? rootSections(), animated: false)
    page.finishTransition()
    return page
  }

  private func rootSections() -> [[Element]] {
    var sections = Self.sections(of: rootMenu)
    if !leadingActions.isEmpty {
      sections.insert(leadingActions.map(Element.action), at: 0)
    }
    return sections
  }

  // MARK: - Sections

  static func sections(of menu: UIMenu) -> [[Element]] {
    var sections: [[Element]] = []
    var loose: [Element] = []
    for child in menu.children {
      if let action = child as? UIAction {
        if !action.attributes.contains(.hidden) { loose.append(.action(action)) }
      } else if let submenu = child as? UIMenu {
        if submenu.options.contains(.displayInline) {
          if !loose.isEmpty {
            sections.append(loose)
            loose = []
          }
          let rows = inlineRows(of: submenu)
          if !rows.isEmpty { sections.append(rows) }
        } else if !submenu.children.isEmpty {
          loose.append(.submenu(submenu))
        }
      }
    }
    if !loose.isEmpty { sections.append(loose) }
    return sections
  }

  private static func inlineRows(of menu: UIMenu) -> [Element] {
    menu.children.flatMap { child -> [Element] in
      if let action = child as? UIAction {
        return action.attributes.contains(.hidden) ? [] : [.action(action)]
      }
      if let submenu = child as? UIMenu {
        return submenu.options.contains(.displayInline) ? inlineRows(of: submenu) : [.submenu(submenu)]
      }
      return []
    }
  }

  // MARK: - Layout

  override func sizeThatFits(_ size: CGSize) -> CGSize {
    maximumWidth = min(style.maximumWidth, size.width)
    pages.forEach { $0.measure(maximumWidth: maximumWidth) }
    return topPage.size
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    platter.frame = bounds
    clipView.frame = platter.contentView.bounds
    // Pages keep their own sizes; a sliding page's position belongs to the transition.
    for page in pages where page.frame.size != page.size {
      page.frame.size = page.size
    }
  }

  // MARK: - Highlight and selection

  /// Highlights the row under `point` (in this view's coordinates); nil clears. Moving between
  /// rows with `feedback` ticks like the system menu.
  func highlightRow(at point: CGPoint?, feedback: Bool) {
    let page = topPage
    let row = point.flatMap { bounds.contains($0) ? page.row(at: convert($0, to: page)) : nil }
    guard row !== page.highlightedRow else { return }
    if row != nil, feedback {
      selectionFeedback.selectionChanged()
      selectionFeedback.prepare()
    }
    page.highlightRow(row)
  }

  /// Picks the highlighted row, if any, and clears the highlight.
  @discardableResult
  func selectHighlightedRow() -> Bool {
    let page = topPage
    guard let row = page.highlightedRow else { return false }
    page.highlightRow(nil)
    onSelect?(row)
    return true
  }

  /// Clears a highlight that a scroll took over.
  func cancelTracking() {
    topPage.highlightRow(nil)
    if tracker.state == .began || tracker.state == .changed {
      tracker.isEnabled = false
      tracker.isEnabled = true
    }
  }

  func prepareFeedback() {
    selectionFeedback.prepare()
  }

  #if DEBUG
  var rowsForTesting: [MessageContextMenuRowView] { topPage.rows }
  /// Every row view in the menu, those fading out included.
  var allRowsForTesting: [MessageContextMenuRowView] {
    pages.flatMap { $0.subviews.compactMap { $0 as? MessageContextMenuRowView } }
  }
  #endif

  @objc private func handleTracking(_ gesture: UILongPressGestureRecognizer) {
    let point = gesture.location(in: self)
    switch gesture.state {
    case .began:
      highlightRow(at: point, feedback: false)
    case .changed:
      highlightRow(at: point, feedback: true)
    case .ended:
      let page = topPage
      if let row = page.highlightedRow, row.bounds.contains(row.convert(point, from: self)) {
        selectHighlightedRow()
      } else {
        page.highlightRow(nil)
      }
    default:
      topPage.highlightRow(nil)
    }
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    // The glass's own touch handling and the column's scrolling run alongside.
    true
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    guard bounds.contains(point), isUserInteractionEnabled, !isHidden, alpha > 0.01 else { return nil }
    // Rows don't take touches; the platter does, so the glass sees them and the tracker runs.
    return platter.contentView
  }
}

/// One level of the menu: its sections of rows, laid out at its own size. New rows match the
/// rows it shows by identity, so rows that stay move instead of being drawn again.
final class MessageContextMenuPageView: UIView {
  var onActivate: ((MessageContextMenuRowView) -> Void)?
  private(set) var size: CGSize = .zero
  private(set) var rows: [MessageContextMenuRowView] = []
  private(set) weak var highlightedRow: MessageContextMenuRowView?

  /// The widest the page may grow; the menu sets it from the room it has.
  var maximumWidth: CGFloat

  private let style: MessageContextMenuStyle
  private var sections: [[MessageContextMenuActionsView.Element]] = []
  private var separators: [String: UIView] = [:]
  private var leaving: [UIView] = []
  private let highlightView = UIView()
  private var measuredWidth: CGFloat?

  init(style: MessageContextMenuStyle, maximumWidth: CGFloat) {
    self.style = style
    self.maximumWidth = maximumWidth
    super.init(frame: .zero)
    highlightView.backgroundColor = style.highlightColor
    highlightView.layer.cornerCurve = .continuous
    highlightView.alpha = 0
    highlightView.isUserInteractionEnabled = false
    addSubview(highlightView)
    isUserInteractionEnabled = false
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// Shows `sections`. Rows already shown with the same identity stay (taking the new action);
  /// with `animated`, new rows and separators fade in where they land and gone ones fade out,
  /// inside the caller's animation.
  func setSections(_ sections: [[MessageContextMenuActionsView.Element]], animated: Bool) {
    self.sections = sections
    var existing: [String: MessageContextMenuRowView] = [:]
    for row in rows { existing[row.key] = row }
    let elements = sections.flatMap(\.self)
    let reservesIconSlot = elements.contains(where: \.hasIcon)
    var seen: [String: Int] = [:]
    var next: [MessageContextMenuRowView] = []
    for element in elements {
      let base = element.identity
      let count = seen[base, default: 0]
      seen[base] = count + 1
      let key = count == 0 ? base : "\(base)#\(count)"
      if let row = existing[key], row.reservesIconSlot == reservesIconSlot {
        existing[key] = nil
        row.update(element)
        next.append(row)
      } else {
        // A row whose icon column changed is replaced; the old one fades out with the rest.
        let row = MessageContextMenuRowView(element: element, key: key, style: style, reservesIconSlot: reservesIconSlot)
        row.onActivate = { [weak self, weak row] in
          guard let self, let row else { return }
          onActivate?(row)
        }
        row.alpha = animated ? 0 : 1
        addSubview(row)
        next.append(row)
      }
    }
    if let highlightedRow, !next.contains(where: { $0 === highlightedRow }) {
      highlightRow(nil)
    }
    leaving += existing.values.map { $0 as UIView }
    rows = next

    // Separators are named by the rows around them, so one between kept rows stays put.
    var kept: [String: UIView] = [:]
    for (key, isSection) in separatorKeys() {
      if let view = separators.removeValue(forKey: key) {
        kept[key] = view
      } else {
        let view = UIView()
        view.backgroundColor = isSection ? style.sectionSeparatorColor : style.rowSeparatorColor
        view.isUserInteractionEnabled = false
        view.alpha = animated ? 0 : 1
        insertSubview(view, at: 0)
        kept[key] = view
      }
    }
    leaving += separators.values
    separators = kept
    measuredWidth = nil
    measure(maximumWidth: maximumWidth)
    // New views start where they land, so they only fade.
    if animated {
      UIView.performWithoutAnimation {
        layoutRows(width: size.width, onlyNew: true)
      }
    }
    setNeedsLayout()
  }

  /// A section separator after each section but the last, named by the row above it; with
  /// row separators, one above every row after a section's first, named by that row.
  private func separatorKeys() -> [(key: String, isSection: Bool)] {
    var keys: [(key: String, isSection: Bool)] = []
    var index = 0
    for (position, section) in sections.enumerated() {
      for offset in section.indices where offset > 0 && style.showsRowSeparators {
        keys.append((key: "row:" + rows[index + offset].key, isSection: false))
      }
      index += section.count
      if position < sections.count - 1 { keys.append((key: "after:" + rows[index - 1].key, isSection: true)) }
    }
    return keys
  }

  /// Settles fades a page change left: shows new rows and drops gone ones.
  func finishTransition() {
    runFades(animated: false, timeScale: 1)
  }

  /// Fixes the page's size for a menu at most `maximumWidth` wide.
  func measure(maximumWidth: CGFloat) {
    self.maximumWidth = maximumWidth
    let natural = rows.map { $0.naturalWidth() }.max() ?? 0
    let width = ceil(min(max(natural, style.minimumWidth), maximumWidth))
    guard measuredWidth != width else { return }
    measuredWidth = width
    size = CGSize(width: width, height: contentHeight(width: width))
  }

  private func contentHeight(width: CGFloat) -> CGFloat {
    var height = style.verticalPadding * 2
    var rowIndex = 0
    for (index, section) in sections.enumerated() {
      if index > 0 { height += style.sectionSpacing }
      for _ in section {
        height += rows[rowIndex].height(forWidth: width)
        rowIndex += 1
      }
    }
    return ceil(height)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    layoutRows(width: bounds.width, onlyNew: false)
  }

  /// Fades out the rows and separators that went away, then fades in the new ones once the kept
  /// rows have moved out of their way.
  func runFades(animated: Bool, timeScale: Double) {
    let appearing = (rows as [UIView] + Array(separators.values)).filter { $0.alpha < 1 }
    let gone = leaving
    leaving.removeAll()
    guard animated else {
      appearing.forEach { $0.alpha = 1 }
      gone.forEach { $0.removeFromSuperview() }
      return
    }
    UIView.animate(withDuration: 0.12 * timeScale, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
      gone.forEach { $0.alpha = 0 }
    } completion: { _ in
      gone.forEach { $0.removeFromSuperview() }
    }
    UIView.animate(withDuration: 0.22 * timeScale, delay: 0.14 * timeScale, options: [.curveEaseIn, .beginFromCurrentState]) {
      appearing.forEach { $0.alpha = 1 }
    }
  }

  /// Lays rows and separators out at `width`; `onlyNew` places just the ones still fading in.
  private func layoutRows(width: CGFloat, onlyNew: Bool) {
    guard width > 0 else { return }
    let scale = window?.screen.scale ?? traitCollection.displayScale
    let hairline = 1 / max(scale, 1)
    func place(_ view: UIView?, _ frame: CGRect) {
      guard let view, !onlyNew || view.alpha < 1 else { return }
      view.frame = frame
      view.layoutIfNeeded()
    }
    var y = style.verticalPadding
    var rowIndex = 0
    for (index, section) in sections.enumerated() {
      if index > 0 {
        let separator = separators["after:" + rows[rowIndex - 1].key]
        switch style.platter {
        case .glass:
          // A line centered in the gap.
          let thickness = style.separatorThickness ?? hairline
          place(separator, CGRect(
            x: style.separatorInset,
            y: y + floor((style.sectionSpacing - thickness) / 2),
            width: max(0, width - style.separatorInset * 2),
            height: thickness
          ))
        case .material:
          place(separator, CGRect(x: 0, y: y, width: width, height: style.sectionSpacing))
        }
        y += style.sectionSpacing
      }
      for offset in section.indices {
        let row = rows[rowIndex]
        rowIndex += 1
        if offset > 0 {
          place(separators["row:" + row.key], CGRect(x: 0, y: y - hairline / 2, width: width, height: hairline))
        }
        let height = row.height(forWidth: width)
        place(row, CGRect(x: 0, y: y, width: width, height: height))
        y += height
      }
    }
    if let highlightedRow, !onlyNew {
      highlightView.frame = highlightFrame(for: highlightedRow)
    }
  }

  // MARK: - Highlight

  func row(at point: CGPoint) -> MessageContextMenuRowView? {
    rows.first { $0.frame.contains(point) && $0.isSelectable }
  }

  func highlightRow(_ row: MessageContextMenuRowView?) {
    highlightedRow = row
    guard let row else {
      UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
        self.highlightView.alpha = 0
      }
      return
    }
    let frame = highlightFrame(for: row)
    highlightView.layer.cornerRadius = style.highlightInset > 0 ? min(style.highlightCornerRadius, frame.height / 2) : 0
    UIView.performWithoutAnimation {
      if highlightView.alpha == 0 { highlightView.frame = frame }
    }
    if highlightView.alpha == 0 {
      UIView.animate(withDuration: 0.1, delay: 0, options: [.allowUserInteraction]) { self.highlightView.alpha = 1 }
    } else {
      highlightView.frame = frame
    }
  }

  private func highlightFrame(for row: MessageContextMenuRowView) -> CGRect {
    row.frame.insetBy(dx: style.highlightInset, dy: 0)
  }
}

/// One menu row. It never takes touches itself (the menu tracks them); it is a control so
/// `sendAction(_:)` can run a `UIAction` with it as the sender.
final class MessageContextMenuRowView: UIControl {
  private(set) var element: MessageContextMenuActionsView.Element
  /// The row's identity in its page: kind, title and attributes.
  let key: String
  let reservesIconSlot: Bool
  var onActivate: (() -> Void)?

  private let style: MessageContextMenuStyle
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  private let iconView = UIImageView()
  private var chevronView: UIImageView?
  private(set) var isSelectable = true

  init(element: MessageContextMenuActionsView.Element, key: String, style: MessageContextMenuStyle, reservesIconSlot: Bool) {
    self.element = element
    self.key = key
    self.style = style
    self.reservesIconSlot = reservesIconSlot
    super.init(frame: .zero)
    isUserInteractionEnabled = false
    backgroundColor = .clear

    var title: String
    var subtitle: String?
    var image: UIImage?
    var color = UIColor.label
    var chevron: String?
    switch element {
    case let .action(action):
      title = action.title
      subtitle = action.subtitle
      image = action.image ?? (action.state == .on ? UIImage(systemName: "checkmark") : nil)
      if action.attributes.contains(.destructive) { color = .systemRed }
      if action.attributes.contains(.disabled) {
        color = .secondaryLabel
        isSelectable = false
      }
    case let .submenu(menu):
      title = menu.title
      subtitle = menu.subtitle
      image = menu.image
      if menu.options.contains(.destructive) { color = .systemRed }
      chevron = "chevron.forward"
    case let .back(menu):
      title = menu.title
      image = UIImage(systemName: "chevron.backward")
    }
    if title.isEmpty, case .back = element { title = "Back" }

    titleLabel.text = title
    titleLabel.font = element.isBack ? style.headerFont : style.titleFont
    titleLabel.textColor = color
    titleLabel.numberOfLines = 0
    titleLabel.adjustsFontForContentSizeCategory = false
    addSubview(titleLabel)

    if let subtitle, !subtitle.isEmpty {
      subtitleLabel.text = subtitle
      subtitleLabel.font = style.subtitleFont
      subtitleLabel.textColor = .secondaryLabel
      subtitleLabel.numberOfLines = 0
      addSubview(subtitleLabel)
    }

    iconView.image = image?.applyingSymbolConfiguration(style.iconConfiguration) ?? image
    iconView.tintColor = color
    iconView.contentMode = .center
    iconView.isHidden = image == nil
    addSubview(iconView)

    if let chevron {
      let view = UIImageView(image: UIImage(
        systemName: chevron,
        withConfiguration: UIImage.SymbolConfiguration(font: style.subtitleFont, scale: .small)
          .applying(UIImage.SymbolConfiguration(weight: .semibold))
      ))
      view.tintColor = .tertiaryLabel
      view.contentMode = .center
      addSubview(view)
      chevronView = view
    }

    isAccessibilityElement = true
    accessibilityLabel = title
    accessibilityValue = subtitle
    accessibilityTraits = isSelectable ? .button : [.button, .notEnabled]
    if case .action(let action) = element, action.state == .on {
      accessibilityTraits.insert(.selected)
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// Takes the action of a rebuilt menu's matching row; it looks the same, so nothing redraws.
  func update(_ element: MessageContextMenuActionsView.Element) {
    self.element = element
  }

  override func accessibilityActivate() -> Bool {
    guard isSelectable else { return false }
    onActivate?()
    return true
  }

  #if DEBUG
  /// The title is laid out narrower or shorter than it needs.
  var isTitleTruncated: Bool {
    guard titleLabel.bounds.width > 0 else { return false }
    let needed = titleLabel.sizeThatFits(CGSize(width: titleLabel.bounds.width, height: .greatestFiniteMagnitude))
    return needed.height > titleLabel.bounds.height + 0.5
  }
  #endif

  // MARK: - Layout

  private var hasSubtitle: Bool { subtitleLabel.superview != nil }

  private var iconSlot: CGFloat {
    reservesIconSlot ? style.iconSlotWidth + style.iconTitleSpacing : 0
  }

  private var chevronWidth: CGFloat {
    guard let chevronView else { return 0 }
    return (chevronView.image?.size.width ?? 0) + 8
  }

  /// Everything but the text.
  private var fixedWidth: CGFloat {
    style.rowSideInset * 2 + iconSlot + chevronWidth
  }

  func naturalWidth() -> CGFloat {
    let unbounded = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
    var text = titleLabel.sizeThatFits(unbounded).width
    if hasSubtitle {
      text = max(text, subtitleLabel.sizeThatFits(unbounded).width)
    }
    return ceil(text + fixedWidth)
  }

  func height(forWidth width: CGFloat) -> CGFloat {
    let textWidth = max(1, width - fixedWidth)
    var height = titleLabel.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
    if hasSubtitle {
      height += 2 + subtitleLabel.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
    }
    return max(style.minimumRowHeight, ceil(height + style.rowVerticalInset * 2))
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
    let width = bounds.width
    let textWidth = max(1, width - fixedWidth)
    let titleHeight = titleLabel.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
    let subtitleHeight = hasSubtitle
      ? subtitleLabel.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height + 2
      : 0
    let textTop = floor((bounds.height - titleHeight - subtitleHeight) / 2)

    // Positions in a left-to-right row; mirrored below for right-to-left.
    let leadsWithIcon = style.iconsLead || element.isBack
    let iconX: CGFloat = leadsWithIcon ? style.rowSideInset : width - style.rowSideInset - style.iconSlotWidth
    let textX: CGFloat = style.rowSideInset + (leadsWithIcon ? iconSlot : 0)
    var frames: [(UIView, CGRect)] = [
      (titleLabel, CGRect(x: textX, y: textTop, width: textWidth, height: titleHeight)),
      (iconView, CGRect(x: iconX, y: 0, width: style.iconSlotWidth, height: bounds.height)),
    ]
    if hasSubtitle {
      frames.append((subtitleLabel, CGRect(x: textX, y: textTop + titleHeight + 2, width: textWidth, height: subtitleHeight - 2)))
    }
    if let chevronView {
      let size = chevronView.image?.size ?? .zero
      let trailing = leadsWithIcon ? width - style.rowSideInset : width - style.rowSideInset - iconSlot
      frames.append((chevronView, CGRect(x: trailing - size.width, y: 0, width: size.width, height: bounds.height)))
    }
    for (view, frame) in frames {
      view.frame = isRTL ? CGRect(x: width - frame.maxX, y: frame.minY, width: frame.width, height: frame.height) : frame
    }
    titleLabel.textAlignment = .natural
    subtitleLabel.textAlignment = .natural
  }
}

extension MessageContextMenuActionsView.Element {
  var isBack: Bool {
    if case .back = self { return true }
    return false
  }

  var hasIcon: Bool {
    switch self {
    case let .action(action): action.image != nil || action.state == .on
    case let .submenu(menu): menu.image != nil
    case .back: true
    }
  }

  /// What makes two rows the same row across menu rebuilds: a rebuilt menu has new `UIAction`s
  /// with new identifiers, so rows match by what they show.
  var identity: String {
    switch self {
    case let .action(action):
      "action|\(action.title)|\(action.subtitle ?? "")|\(action.attributes.rawValue)|\(action.state.rawValue)"
    case let .submenu(menu):
      "menu|\(menu.title)"
    case let .back(menu):
      "back|\(menu.title)"
    }
  }
}
