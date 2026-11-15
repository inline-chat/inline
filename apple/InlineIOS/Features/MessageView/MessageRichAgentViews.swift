import Combine
import InlineKit
import InlineMessageLayout
import struct InlineProtocol.MessageAction
import UIKit

/// The message a rich body belongs to, for blocks with their own buttons.
struct MessageRichActionContext {
  let message: Message
  /// `message.actions` by ID.
  let actions: [String: MessageAction]

  init(message: Message) {
    self.message = message
    actions = BlockInlineActions.byID(message.actions)
  }
}

// MARK: - Card

/// Draws an agent block's planned parts: task lists, fields, meters, callouts, plans,
/// approvals, reviews, task suggestions, next steps and prompt suggestions. Geometry comes from
/// the plan; this view only places parts and handles taps. Blocks with children sit behind
/// them, and touches outside its own controls pass through to the message.
final class RichCardView: UIView {
  private var card: RichLayout.Card?
  private var palette: MessageRichView.Palette?
  private var partViews: [UIView] = []
  private var signature: [Int] = []
  private var context: MessageRichActionContext?
  private var loadingSubscription: AnyCancellable?
  private var answeredSubscription: AnyCancellable?
  private var grantsSubscription: AnyCancellable?
  var onToggle: ((RichPath, Bool) -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    clipsToBounds = false
    isAccessibilityElement = false
    registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _: UITraitCollection) in
      self.updateChrome()
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// Only its controls take touches; text and children behind or above it stay the message's.
  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    let hit = super.hitTest(point, with: event)
    return hit === self ? nil : hit
  }

  func configure(_ card: RichLayout.Card, palette: MessageRichView.Palette, context: MessageRichActionContext?) {
    self.card = card
    self.palette = palette
    self.context = context
    let newSignature = card.parts.map(Self.kind)
    if newSignature != signature {
      partViews.forEach { $0.removeFromSuperview() }
      partViews = card.parts.map(makeView)
      partViews.forEach(addSubview)
      signature = newSignature
    }
    for (view, part) in zip(partViews, card.parts) {
      configure(view, part: part, palette: palette)
    }
    alpha = card.isMuted ? 0.55 : 1
    updateChrome()
    updateAccessibility()
    subscribe()
    updateButtons()
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard let card else { return }
    for (view, part) in zip(partViews, card.parts) {
      if let text = view as? MessageTextView {
        text.textFrame = part.frame
      } else {
        view.untransformedFrame = part.frame
      }
      view.layoutIfNeeded()
    }
  }

  /// Text under `point` in this view's coordinates, for links in card text.
  func textHit(at point: CGPoint) -> (NSAttributedString, Int)? {
    for view in partViews {
      guard let text = view as? MessageTextView, text.frame.insetBy(dx: -4, dy: -2).contains(point),
            let index = text.characterIndex(at: convert(point, to: text))
      else { continue }
      return (text.layout.text.attributedString, index)
    }
    return nil
  }

  // MARK: Chrome

  private func updateChrome() {
    guard let card, let palette else { return }
    let traits = traitCollection
    let hairline = 1 / max(traits.displayScale, 1)
    var fill: UIColor = .clear
    var border: UIColor?
    var radius: CGFloat = 12
    switch card.style {
    case .plain:
      radius = 0
    case .taskList:
      fill = palette.subtleFill
      border = palette.separator
      radius = 10
    case let .callout(tone):
      let tint = tone.color(accent: palette.accent, secondary: palette.secondary)
      fill = tint.withAlphaComponent(0.08)
      border = tint.withAlphaComponent(0.22)
      radius = 10
    case .plan, .approval, .review, .taskSuggestion:
      fill = palette.subtleFill
      border = palette.separator
    case .nextStep:
      fill = palette.subtleFill
    }
    backgroundColor = fill
    layer.cornerRadius = radius
    layer.cornerCurve = .continuous
    layer.borderWidth = border == nil ? 0 : hairline
    layer.borderColor = border?.resolvedColor(with: traits).cgColor
  }

  // MARK: Parts

  private static func kind(of part: RichLayout.Card.Part) -> Int {
    switch part.kind {
    case .text: 0
    case .symbol: 1
    case .chip: 2
    case .button: 3
    case .box: 4
    case .bar: 5
    case .separator: 6
    case .row: 7
    }
  }

  private func makeView(for part: RichLayout.Card.Part) -> UIView {
    switch part.kind {
    case .text:
      let view = MessageTextView()
      view.isAccessibilityElement = true
      view.accessibilityTraits = .staticText
      return view
    case .symbol:
      return RichSymbolView()
    case .chip:
      return RichChipView()
    case .button:
      let button = RichCardButton()
      button.addTarget(self, action: #selector(handleControl(_:)), for: .touchUpInside)
      return button
    case .box:
      let view = UIView()
      view.layer.cornerRadius = 7
      view.layer.cornerCurve = .continuous
      view.isUserInteractionEnabled = false
      return view
    case .bar:
      return RichBarView()
    case .separator:
      let view = UIView()
      view.isUserInteractionEnabled = false
      return view
    case .row:
      let row = RichRowControl()
      row.addTarget(self, action: #selector(handleControl(_:)), for: .touchUpInside)
      return row
    }
  }

  private func configure(_ view: UIView, part: RichLayout.Card.Part, palette: MessageRichView.Palette) {
    switch part.kind {
    case let .text(layout):
      guard let view = view as? MessageTextView else { return }
      view.setLayout(layout)
      view.accessibilityLabel = layout.text.string
    case let .symbol(symbol):
      (view as? RichSymbolView)?.configure(symbol, palette: palette)
    case let .chip(text, tone, symbol):
      (view as? RichChipView)?.configure(text: text, tone: tone, symbol: symbol, palette: palette)
    case let .button(title, style):
      (view as? RichCardButton)?.configure(title: title, style: style, tap: part.tap, palette: palette)
    case .box:
      view.backgroundColor = palette.codeFill
    case let .bar(fraction, tone):
      (view as? RichBarView)?.configure(fraction: fraction, tint: tone.color(accent: palette.accent, secondary: palette.secondary), palette: palette)
    case .separator:
      view.backgroundColor = palette.separator
    case .row:
      (view as? RichRowControl)?.configure(tap: part.tap, palette: palette)
    }
  }

  /// Reading order follows the parts. A step's status reads with its text; a tappable row
  /// reads as one button with the text on it.
  private func updateAccessibility() {
    guard let card else { return }
    var elements: [UIView] = []
    var claimed = Set<Int>()
    for (index, part) in card.parts.enumerated() where !claimed.contains(index) {
      let view = partViews[index]
      switch part.kind {
      case let .symbol(.status(status)):
        if index + 1 < card.parts.count, case let .text(text) = card.parts[index + 1].kind {
          partViews[index + 1].accessibilityLabel = "\(Self.name(of: status)), \(text.text.string)"
        }
      case .row:
        var label: [String] = []
        for (other, candidate) in card.parts.enumerated() where other > index {
          guard case let .text(text) = candidate.kind, part.frame.intersects(candidate.frame) else { continue }
          label.append(text.text.string)
          claimed.insert(other)
        }
        view.accessibilityLabel = label.joined(separator: ", ")
        if case let .toggle(_, expands)? = part.tap {
          view.accessibilityValue = expands ? String(localized: "Collapsed") : String(localized: "Expanded")
        }
        elements.append(view)
      case .text, .button, .chip, .bar:
        elements.append(view)
      case .symbol, .box, .separator:
        break
      }
    }
    accessibilityElements = elements
  }

  static func name(of status: RichStatus) -> String {
    switch status {
    case .pending: String(localized: "Pending")
    case .running: String(localized: "In progress")
    case .waiting: String(localized: "Waiting for you")
    case .done: String(localized: "Done")
    case .failed: String(localized: "Failed")
    case .cancelled: String(localized: "Cancelled")
    }
  }

  // MARK: Actions

  private var actionIDs: [String] {
    card?.parts.compactMap { if case let .action(id)? = $0.tap { id } else { nil } } ?? []
  }

  private func subscribe() {
    guard !actionIDs.isEmpty, loadingSubscription == nil else { return }
    loadingSubscription = MessageActionInteractionState.shared.loadingPublisher
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.updateButtons() }
    grantsSubscription = AgentGrantStore.shared.$accessByBotUserID
      .removeDuplicates()
      .dropFirst()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.updateButtons() }
    answeredSubscription = MessageActionInteractionState.shared.answeredPublisher
      .receive(on: DispatchQueue.main)
      .sink { [weak self] event in
        guard let self, let message = context?.message,
              event.key.peerId == message.peerId, event.key.messageId == message.messageId,
              actionIDs.contains(event.key.actionId)
        else { return }
        if let toastText = event.toastText {
          ToastManager.shared.showToast(toastText, type: .info)
        }
        if let alert = event.alert {
          MessageActionPerformer.presentAlert(alert, from: self)
        }
      }
  }

  /// Loading spinners, and dimmed titles for actions the viewer can't use.
  private func updateButtons() {
    guard let card, let context else { return }
    for (view, part) in zip(partViews, card.parts) {
      guard let button = view as? RichCardButton, case let .action(id)? = part.tap else { continue }
      guard let action = context.actions[id] else {
        button.setAvailable(false, reason: nil)
        continue
      }
      let presentation = MessageActionPerformer.presentation(for: action, message: context.message)
      button.setAvailable(presentation.isEnabled, reason: presentation.disabledReason)
      button.setLoading(MessageActionInvoker.isLoading(id, on: context.message))
    }
  }

  @objc private func handleControl(_ sender: UIControl) {
    let tap = (sender as? RichCardButton)?.tap ?? (sender as? RichRowControl)?.tap
    guard let tap else { return }
    switch tap {
    case let .action(id):
      guard let context, let action = context.actions[id] else { return }
      MessageActionInvoker.tap(action, on: context.message, from: self)
    case let .compose(text):
      guard let message = context?.message else { return }
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
      MessageComposeRequests.shared.post(text, from: message)
    case let .toggle(path, isExpanded):
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
      onToggle?(path, isExpanded)
    case let .openThread(id):
      ThreadLinkNavigator.navigate(to: .thread(id: id))
    case let .openUser(id):
      ThreadLinkNavigator.navigate(to: .user(id: id))
    }
  }
}

// MARK: - Part views

/// A step's marker or a block's glyph. A running step spins.
private final class RichSymbolView: UIView {
  private let image = UIImageView()
  private var spinner: UIActivityIndicatorView?

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    image.contentMode = .scaleAspectFit
    addSubview(image)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(_ symbol: RichSymbol, palette: MessageRichView.Palette) {
    var name: String?
    var tint = palette.secondary
    var isRunning = false
    switch symbol {
    case let .named(symbolName, tone):
      name = symbolName
      tint = tone.color(accent: palette.accent, secondary: palette.secondary)
    case let .status(status):
      switch status {
      case .pending: name = "circle.dashed"; tint = palette.secondary.withAlphaComponent(0.75)
      case .running: isRunning = true
      case .waiting: name = "hand.raised.fill"; tint = .systemOrange
      case .done: name = "checkmark.circle.fill"; tint = .systemGreen
      case .failed: name = "xmark.circle.fill"; tint = .systemRed
      case .cancelled: name = "slash.circle"; tint = palette.secondary.withAlphaComponent(0.75)
      }
    }
    image.isHidden = isRunning
    if let name {
      image.image = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(weight: .medium))
      image.tintColor = tint
    }
    if isRunning {
      let spinner = spinner ?? {
        let view = UIActivityIndicatorView(style: .medium)
        view.hidesWhenStopped = true
        addSubview(view)
        self.spinner = view
        return view
      }()
      spinner.color = palette.secondary
      spinner.startAnimating()
    } else {
      spinner?.stopAnimating()
    }
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    image.frame = bounds
    if let spinner {
      // The standard spinner, scaled into the marker's frame.
      let natural: CGFloat = 20
      let scale = min(bounds.width, bounds.height) / natural
      spinner.bounds = CGRect(x: 0, y: 0, width: natural, height: natural)
      spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
      spinner.transform = CGAffineTransform(scaleX: scale, y: scale)
    }
  }
}

/// A capsule with a short label: a plan's state, a priority, a verdict.
private final class RichChipView: UIView {
  private let text = MessageTextView()
  private let image = UIImageView()
  private var hasSymbol = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    layer.cornerCurve = .continuous
    image.contentMode = .scaleAspectFit
    addSubview(image)
    addSubview(text)
    isAccessibilityElement = true
    accessibilityTraits = .staticText
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(text layout: TextLayout, tone: RichTone, symbol: String?, palette: MessageRichView.Palette) {
    let tint = tone.color(accent: palette.accent, secondary: palette.secondary)
    backgroundColor = tint.withAlphaComponent(tone == .neutral ? 0.12 : 0.15)
    text.setLayout(layout)
    hasSymbol = symbol != nil
    image.isHidden = symbol == nil
    image.image = symbol.flatMap { UIImage(systemName: $0, withConfiguration: UIImage.SymbolConfiguration(weight: .semibold)) }
    image.tintColor = tint
    accessibilityLabel = layout.text.string
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let metrics = RichLayoutMetrics()
    layer.cornerRadius = bounds.height / 2
    let size = text.layout.size
    let side = hasSymbol ? (size.height * 0.85).rounded() : 0
    let isRightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
      && text.layout.lines.first?.direction == .rightToLeft
    var x = metrics.chipHorizontalPadding
    if hasSymbol {
      image.frame = CGRect(
        x: isRightToLeft ? bounds.width - x - side : x,
        y: (bounds.height - side) / 2,
        width: side,
        height: side
      )
      x += side + metrics.chipSymbolGap
    }
    text.textFrame = CGRect(
      x: isRightToLeft ? bounds.width - x - size.width : x,
      y: (bounds.height - size.height) / 2,
      width: size.width,
      height: size.height
    )
  }
}

/// A block's own button: the message action styles, a capsule for prompt suggestions, and a
/// spinner while its callback runs.
final class RichCardButton: UIControl {
  private let title = MessageTextView()
  private let spinner = UIActivityIndicatorView(style: .medium)
  private var style: RichButton.Style = .standard
  private var palette: MessageRichView.Palette?
  private var isAvailable = true
  private(set) var tap: RichTap?

  override var isHighlighted: Bool {
    didSet { updatePress() }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    layer.cornerCurve = .continuous
    spinner.hidesWhenStopped = true
    spinner.transform = CGAffineTransform(scaleX: 0.82, y: 0.82)
    addSubview(title)
    addSubview(spinner)
    isAccessibilityElement = true
    accessibilityTraits = .button
    registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _: UITraitCollection) in
      self.updateStyle()
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(title layout: TextLayout, style: RichButton.Style, tap: RichTap?, palette: MessageRichView.Palette) {
    title.setLayout(layout)
    self.style = style
    self.tap = tap
    self.palette = palette
    accessibilityLabel = layout.text.string
    if case .compose = tap {
      accessibilityHint = String(localized: "Puts this text in the message field")
    }
    updateStyle()
    setNeedsLayout()
  }

  /// Unavailable actions stay tappable so the tap can explain why.
  func setAvailable(_ isAvailable: Bool, reason: String?) {
    self.isAvailable = isAvailable
    accessibilityHint = reason
    title.alpha = isAvailable ? 1 : 0.45
    updateStyle()
  }

  func setLoading(_ isLoading: Bool) {
    isEnabled = !isLoading
    title.isHidden = isLoading
    if isLoading {
      spinner.color = style == .primary ? .white : palette?.secondary
      spinner.startAnimating()
    } else {
      spinner.stopAnimating()
    }
    accessibilityValue = isLoading ? String(localized: "In progress") : nil
  }

  private func updateStyle() {
    guard let palette else { return }
    let isDark = traitCollection.userInterfaceStyle == .dark
    let hairline = 1 / max(traitCollection.displayScale, 1)
    layer.borderWidth = 0
    switch style {
    case .primary where isAvailable:
      backgroundColor = palette.accent == .white ? UIColor.white.withAlphaComponent(0.26) : palette.accent
    case .suggestion:
      backgroundColor = .clear
      layer.borderWidth = hairline
      layer.borderColor = palette.separator.resolvedColor(with: traitCollection).cgColor
    default:
      backgroundColor = palette.text.withAlphaComponent(isDark ? 0.11 : 0.06)
    }
    setNeedsLayout()
  }

  private func updatePress() {
    let pressed = isEnabled && isHighlighted
    UIView.animate(withDuration: 0.14, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
      self.alpha = pressed ? 0.85 : 1
      self.transform = pressed ? CGAffineTransform(scaleX: 0.97, y: 0.97) : .identity
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    layer.cornerRadius = style == .suggestion ? bounds.height / 2 : 10
    let size = title.layout.size
    title.textFrame = CGRect(
      x: ((bounds.width - size.width) / 2).rounded(),
      y: ((bounds.height - size.height) / 2).rounded(),
      width: size.width,
      height: size.height
    )
    spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
  }
}

/// A tappable row behind its texts: a toggle, a finding or a link line.
final class RichRowControl: UIControl {
  private(set) var tap: RichTap?
  private var highlight: UIColor = .clear

  override var isHighlighted: Bool {
    didSet {
      UIView.animate(withDuration: isHighlighted ? 0.05 : 0.2, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
        self.backgroundColor = self.isHighlighted ? self.highlight : .clear
      }
    }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    layer.cornerRadius = 8
    layer.cornerCurve = .continuous
    isAccessibilityElement = true
    accessibilityTraits = .button
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(tap: RichTap?, palette: MessageRichView.Palette) {
    self.tap = tap
    highlight = palette.text.withAlphaComponent(0.08)
  }
}

/// A meter's bar.
private final class RichBarView: UIView {
  private let fill = UIView()
  private var fraction: Double = 0

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    clipsToBounds = true
    addSubview(fill)
    isAccessibilityElement = true
    accessibilityTraits = .updatesFrequently
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(fraction: Double, tint: UIColor, palette: MessageRichView.Palette) {
    self.fraction = fraction
    backgroundColor = palette.text.withAlphaComponent(0.1)
    fill.backgroundColor = tint
    accessibilityValue = "\(Int((fraction * 100).rounded()))%"
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    layer.cornerRadius = bounds.height / 2
    fill.layer.cornerRadius = bounds.height / 2
    let width = bounds.width * fraction
    let isRightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
    fill.frame = CGRect(x: isRightToLeft ? bounds.width - width : 0, y: 0, width: width, height: bounds.height)
  }
}

// MARK: - Diff

/// One file's diff: the path and counts, and the unified diff with added and removed lines
/// tinted, scrolling sideways.
final class RichDiffView: UIView, RichScrollResetting {
  private let icon = UIImageView()
  private let pathLabel = UILabel()
  private let counts = MessageTextView()
  private let copyButton = UIButton(type: .system)
  private let scroll = UIScrollView()
  private let stripes = RichDiffStripesView()
  private let body = MessageTextView()
  private let footer = MessageTextView()
  private var diff: RichLayout.Diff?
  var needsScrollReset = true

  override init(frame: CGRect) {
    super.init(frame: frame)
    layer.cornerRadius = 8
    layer.cornerCurve = .continuous
    clipsToBounds = true
    icon.contentMode = .scaleAspectFit
    pathLabel.lineBreakMode = .byTruncatingMiddle
    pathLabel.numberOfLines = 1
    scroll.showsHorizontalScrollIndicator = false
    scroll.alwaysBounceHorizontal = false
    addSubview(icon)
    addSubview(pathLabel)
    addSubview(counts)
    addSubview(scroll)
    scroll.addSubview(stripes)
    scroll.addSubview(body)
    scroll.addSubview(footer)
    copyButton.setImage(UIImage(systemName: "doc.on.doc", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .medium)), for: .normal)
    copyButton.addTarget(self, action: #selector(copyDiff), for: .touchUpInside)
    copyButton.accessibilityLabel = String(localized: "Copy diff")
    addSubview(copyButton)
    pathLabel.isAccessibilityElement = true
    body.isAccessibilityElement = true
    body.accessibilityTraits = .staticText
    accessibilityElements = [pathLabel, body, copyButton]
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(_ diff: RichLayout.Diff, palette: MessageRichView.Palette) {
    if let previous = self.diff, previous.body?.text != diff.body?.text,
       !(diff.body?.text.string ?? "").hasPrefix(previous.body?.text.string ?? "")
    {
      needsScrollReset = true
    }
    self.diff = diff
    backgroundColor = palette.codeFill
    icon.image = UIImage(systemName: diff.symbol, withConfiguration: UIImage.SymbolConfiguration(weight: .medium))
    icon.tintColor = palette.secondary
    pathLabel.attributedText = diff.path.attributedString
    counts.setLayout(diff.counts ?? .empty)
    counts.isHidden = diff.counts == nil
    body.setLayout(diff.body ?? .empty)
    footer.setLayout(diff.footer ?? .empty)
    scroll.isHidden = diff.body == nil
    copyButton.isHidden = diff.body == nil
    copyButton.tintColor = palette.secondary
    stripes.configure(diff.body)
    let path = diff.path.string
    let countsText = diff.counts.map { ", \($0.text.string)" } ?? ""
    pathLabel.accessibilityLabel = String(localized: "Changes to \(path)") + countsText
    body.accessibilityLabel = diff.body?.text.string
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard let diff else { return }
    icon.frame = diff.symbolFrame
    pathLabel.frame = diff.pathFrame
    counts.textFrame = diff.countsFrame
    copyButton.frame = diff.copyFrame
    scroll.frame = CGRect(x: 0, y: diff.headerHeight, width: bounds.width, height: max(0, bounds.height - diff.headerHeight))
    scroll.contentSize = CGSize(width: diff.contentWidth, height: scroll.bounds.height)
    if needsScrollReset {
      needsScrollReset = false
      UIView.performWithoutAnimation { scroll.contentOffset = .zero }
    }
    let origin = CGPoint(x: diff.bodyOrigin.x, y: diff.bodyOrigin.y - diff.headerHeight)
    if let layout = diff.body {
      body.textFrame = CGRect(origin: origin, size: layout.size)
      stripes.frame = CGRect(x: 0, y: origin.y, width: max(diff.contentWidth, bounds.width), height: layout.size.height)
    }
    if let layout = diff.footer {
      footer.textFrame = CGRect(origin: CGPoint(x: diff.footerOrigin.x, y: diff.footerOrigin.y - diff.headerHeight), size: layout.size)
    }
  }

  @objc private func copyDiff() {
    guard let text = diff?.body?.text.string, !text.isEmpty else { return }
    UIPasteboard.general.string = text
    ToastManager.shared.showToast("Copied", type: .success, systemImage: "doc.on.doc")
  }
}

/// Full-width tints behind added and removed lines.
private final class RichDiffStripesView: UIView {
  private var marks: [(CGRect, Bool)] = []

  override init(frame: CGRect) {
    super.init(frame: frame)
    isOpaque = false
    backgroundColor = .clear
    contentMode = .redraw
    isUserInteractionEnabled = false
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(_ layout: TextLayout?) {
    marks = []
    if let layout {
      let string = layout.text.string as NSString
      for line in layout.lines where line.range.length > 0 {
        let first = string.character(at: line.range.location)
        let prefix = string.substring(with: NSRange(location: line.range.location, length: min(3, line.range.length)))
        if first == 43, prefix != "+++" {
          marks.append((line.frame, true))
        } else if first == 45, prefix != "---" {
          marks.append((line.frame, false))
        }
      }
    }
    setNeedsDisplay()
  }

  override func draw(_ rect: CGRect) {
    for (frame, isAddition) in marks {
      (isAddition ? UIColor.systemGreen : UIColor.systemRed).withAlphaComponent(0.14).setFill()
      UIRectFill(CGRect(x: 0, y: frame.minY, width: bounds.width, height: frame.height))
    }
  }
}
