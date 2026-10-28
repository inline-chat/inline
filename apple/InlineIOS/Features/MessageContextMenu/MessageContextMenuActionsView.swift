import UIKit

/// The menu's actions, drawn like the platform menu from a `UIMenu`. Inline menus become
/// sections, other menus open in place behind a back row, and rows run their actions through
/// `UIControl.sendAction`, so the chat's one menu builder serves both menus.
///
/// Touches anywhere on the menu highlight the row under the finger and pick it on lift; the
/// host forwards the opening hold's finger the same way, so a press can slide onto an action.
final class MessageContextMenuActionsView: UIView {
  enum Element {
    case action(UIAction)
    case submenu(UIMenu)
    /// The header of an opened submenu; picking it goes back.
    case back(UIMenu)
  }

  /// A row was picked by tap, drag-release or VoiceOver.
  var onSelect: ((MessageContextMenuRowView) -> Void)?
  /// The rows changed size, as when a submenu opens; the host lays the menu out again.
  var onContentSizeChange: (() -> Void)?

  let style: MessageContextMenuStyle
  private let platter: UIVisualEffectView
  private let highlightView = UIView()
  private var rowViews: [MessageContextMenuRowView] = []
  private var separatorViews: [UIView] = []
  private var rootMenu: UIMenu
  private var leadingActions: [UIAction] = []
  private var openSubmenus: [UIMenu] = []
  private var sections: [[Element]] = []
  private weak var highlightedRow: MessageContextMenuRowView?
  private let selectionFeedback = UISelectionFeedbackGenerator()

  init(menu: UIMenu, style: MessageContextMenuStyle) {
    rootMenu = menu
    self.style = style
    platter = style.makePlatter()
    super.init(frame: .zero)
    addSubview(platter)
    highlightView.backgroundColor = style.highlightColor
    highlightView.layer.cornerCurve = .continuous
    highlightView.alpha = 0
    highlightView.isUserInteractionEnabled = false
    platter.contentView.addSubview(highlightView)
    rebuildRows(animated: false)
    accessibilityContainerType = .list
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// Replaces the menu and the actions shown above it, closing any open submenu.
  func setMenu(_ menu: UIMenu, leadingActions: [UIAction], animated: Bool) {
    rootMenu = menu
    self.leadingActions = leadingActions
    openSubmenus.removeAll()
    rebuildRows(animated: animated)
  }

  func open(_ submenu: UIMenu) {
    openSubmenus.append(submenu)
    rebuildRows(animated: true)
  }

  func goBack() {
    guard !openSubmenus.isEmpty else { return }
    openSubmenus.removeLast()
    rebuildRows(animated: true)
  }

  var firstRow: UIView? { rowViews.first }

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

  private func currentSections() -> [[Element]] {
    if let submenu = openSubmenus.last {
      return [[.back(submenu)]] + Self.sections(of: submenu)
    }
    var sections = Self.sections(of: rootMenu)
    if !leadingActions.isEmpty {
      sections.insert(leadingActions.map(Element.action), at: 0)
    }
    return sections
  }

  private func rebuildRows(animated: Bool) {
    clearHighlight()
    let outgoing = rowViews + separatorViews
    sections = currentSections()
    let elements = sections.flatMap(\.self)
    let reservesIconSlot = elements.contains { element in
      switch element {
      case let .action(action): action.image != nil || action.state == .on
      case let .submenu(menu): menu.image != nil
      case .back: true
      }
    }
    rowViews = elements.map { element in
      let row = MessageContextMenuRowView(element: element, style: style, reservesIconSlot: reservesIconSlot)
      row.onActivate = { [weak self, weak row] in
        guard let self, let row else { return }
        onSelect?(row)
      }
      return row
    }
    var separators: [UIView] = []
    for (index, section) in sections.enumerated() {
      if index > 0 {
        let view = UIView()
        view.backgroundColor = style.sectionSeparatorColor
        view.isUserInteractionEnabled = false
        separators.append(view)
      }
      if style.showsRowSeparators, section.count > 1 {
        for _ in 1 ..< section.count {
          let view = UIView()
          view.backgroundColor = style.rowSeparatorColor
          view.isUserInteractionEnabled = false
          separators.append(view)
        }
      }
    }
    separatorViews = separators
    for view in separatorViews + rowViews {
      platter.contentView.addSubview(view)
    }

    guard animated, !UIAccessibility.isReduceMotionEnabled else {
      outgoing.forEach { $0.removeFromSuperview() }
      setNeedsLayout()
      onContentSizeChange?()
      return
    }
    for view in separatorViews + rowViews {
      view.alpha = 0
    }
    // Lay the new rows out at the current width so they fade in place while the platter resizes.
    layoutRows(width: bounds.width)
    UIView.animate(withDuration: 0.18, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut]) {
      outgoing.forEach { $0.alpha = 0 }
      (self.separatorViews + self.rowViews).forEach { $0.alpha = 1 }
    } completion: { _ in
      outgoing.forEach { $0.removeFromSuperview() }
    }
    onContentSizeChange?()
  }

  // MARK: - Layout

  override func sizeThatFits(_ size: CGSize) -> CGSize {
    let natural = rowViews.map { $0.naturalWidth() }.max() ?? 0
    let maximum = min(style.maximumWidth, size.width)
    let width = ceil(min(max(natural, style.minimumWidth), maximum))
    return CGSize(width: width, height: contentHeight(width: width))
  }

  private func contentHeight(width: CGFloat) -> CGFloat {
    var height = style.verticalPadding * 2
    var rowIndex = 0
    for (index, section) in sections.enumerated() {
      if index > 0 { height += style.sectionSpacing }
      for _ in section {
        height += rowViews[rowIndex].height(forWidth: width)
        rowIndex += 1
      }
    }
    return ceil(height)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    platter.frame = bounds
    layoutRows(width: bounds.width)
  }

  private func layoutRows(width: CGFloat) {
    let scale = window?.screen.scale ?? traitCollection.displayScale
    let hairline = 1 / max(scale, 1)
    var y = style.verticalPadding
    var rowIndex = 0
    var separatorIndex = 0
    for (index, section) in sections.enumerated() {
      if index > 0 {
        let separator = separatorViews[separatorIndex]
        separatorIndex += 1
        switch style.platter {
        case .glass:
          // A line centered in the gap, inset like the rows.
          separator.frame = CGRect(
            x: style.rowSideInset,
            y: y + floor((style.sectionSpacing - hairline) / 2),
            width: max(0, width - style.rowSideInset * 2),
            height: hairline
          )
        case .material:
          separator.frame = CGRect(x: 0, y: y, width: width, height: style.sectionSpacing)
        }
        y += style.sectionSpacing
      }
      for position in section.indices {
        let row = rowViews[rowIndex]
        rowIndex += 1
        if style.showsRowSeparators, position > section.startIndex {
          separatorViews[separatorIndex].frame = CGRect(x: 0, y: y - hairline / 2, width: width, height: hairline)
          separatorIndex += 1
        }
        let height = row.height(forWidth: width)
        row.frame = CGRect(x: 0, y: y, width: width, height: height)
        y += height
      }
    }
    if let highlightedRow {
      highlightView.frame = highlightFrame(for: highlightedRow)
    }
  }

  private func highlightFrame(for row: MessageContextMenuRowView) -> CGRect {
    row.frame.insetBy(dx: style.highlightInset, dy: 0)
  }

  // MARK: - Highlight and selection

  private func row(at point: CGPoint) -> MessageContextMenuRowView? {
    guard bounds.contains(point) else { return nil }
    return rowViews.first { $0.frame.contains(point) && $0.isSelectable }
  }

  /// Highlights the row under `point` (in this view's coordinates); nil clears. Moving between
  /// rows with `feedback` ticks like the system menu.
  func highlightRow(at point: CGPoint?, feedback: Bool) {
    let row = point.flatMap(row(at:))
    guard row !== highlightedRow else { return }
    highlightedRow = row
    guard let row else {
      clearHighlight()
      return
    }
    if feedback {
      selectionFeedback.selectionChanged()
      selectionFeedback.prepare()
    }
    let frame = highlightFrame(for: row)
    highlightView.layer.cornerRadius = style.highlightInset > 0 ? min(20, frame.height / 2) : 0
    if highlightView.alpha == 0 {
      highlightView.frame = frame
      UIView.animate(withDuration: 0.1) { self.highlightView.alpha = 1 }
    } else {
      highlightView.frame = frame
    }
  }

  private func clearHighlight() {
    highlightedRow = nil
    UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState]) {
      self.highlightView.alpha = 0
    }
  }

  /// Picks the highlighted row, if any, and clears the highlight.
  @discardableResult
  func selectHighlightedRow() -> Bool {
    guard let row = highlightedRow else { return false }
    clearHighlight()
    onSelect?(row)
    return true
  }

  func prepareFeedback() {
    selectionFeedback.prepare()
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard let touch = touches.first else { return }
    highlightRow(at: touch.location(in: self), feedback: false)
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard let touch = touches.first else { return }
    highlightRow(at: touch.location(in: self), feedback: true)
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard let touch = touches.first, let row = highlightedRow, row.frame.contains(touch.location(in: self)) else {
      clearHighlight()
      return
    }
    selectHighlightedRow()
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
    clearHighlight()
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    // Rows don't take touches themselves; the menu tracks them so a drag moves the highlight.
    bounds.contains(point) && isUserInteractionEnabled && !isHidden && alpha > 0.01 ? self : nil
  }
}

/// One menu row. It never takes touches itself (the menu tracks them); it is a control so
/// `sendAction(_:)` can run a `UIAction` with it as the sender.
final class MessageContextMenuRowView: UIControl {
  let element: MessageContextMenuActionsView.Element
  var onActivate: (() -> Void)?

  private let style: MessageContextMenuStyle
  private let reservesIconSlot: Bool
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  private let iconView = UIImageView()
  private var chevronView: UIImageView?
  private(set) var isSelectable = true

  init(element: MessageContextMenuActionsView.Element, style: MessageContextMenuStyle, reservesIconSlot: Bool) {
    self.element = element
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

  override func accessibilityActivate() -> Bool {
    guard isSelectable else { return false }
    onActivate?()
    return true
  }

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
    return max(44, ceil(height + style.rowVerticalInset * 2))
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

private extension MessageContextMenuActionsView.Element {
  var isBack: Bool {
    if case .back = self { return true }
    return false
  }
}
