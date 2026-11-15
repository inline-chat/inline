import AppKit
import InlineKit
import InlineProtocol

// MARK: - Shared parts

private func makeSymbolView(pointSize: CGFloat, weight: NSFont.Weight = .medium) -> NSImageView {
  let view = NSImageView(frame: .zero)
  view.imageScaling = .scaleProportionallyDown
  view.symbolConfiguration = .init(pointSize: pointSize, weight: weight)
  view.setAccessibilityElement(false)
  return view
}

private func makeLabel(font: NSFont) -> NSTextField {
  let label = NSTextField(labelWithString: "")
  label.font = font
  label.lineBreakMode = .byTruncatingTail
  label.maximumNumberOfLines = 1
  label.cell?.truncatesLastVisibleLine = true
  return label
}

/// A small tinted label: a state, a verdict or a priority.
final class RichBlockChipView: NSView {
  private let label = makeLabel(font: RichBlockAgentCardMetrics.chipFont)
  private var tone: RichBlockChipTone = .neutral

  override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.cornerRadius = RichBlockAgentCardMetrics.chipHeight / 2
    layer?.cornerCurve = .continuous
    label.alignment = .center
    addSubview(label)
    setAccessibilityElement(true)
    setAccessibilityRole(.staticText)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func apply(_ chip: RichBlockChip) {
    tone = chip.tone
    label.stringValue = chip.text
    label.textColor = chip.tone.tint
    setAccessibilityLabel(chip.text)
    updateColors()
    needsLayout = true
  }

  override func layout() {
    super.layout()
    let height = ceil(label.intrinsicContentSize.height)
    label.frame = CGRect(x: 0, y: floor((bounds.height - height) / 2), width: bounds.width, height: height)
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateColors()
  }

  private func updateColors() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = tone.tint.withAlphaComponent(0.13).cgColor
    }
  }
}

// MARK: - Card chrome

/// Background, icon, header and chip of a plan proposal, approval, task suggestion or next
/// step. The card's body blocks and buttons are their own nodes, drawn over it.
final class RichBlockAgentCardNodeView: RichBlockRenderableView {
  private let icon = makeSymbolView(pointSize: 12)
  private let title = RichBlockTextSurface(frame: .zero)
  private let titleLiteral = makeLabel(font: RichBlockAgentCardMetrics.titleFont)
  private let chip = RichBlockChipView(frame: .zero)
  private let commandBox = NSView(frame: .zero)
  private let command = RichBlockTextSurface(frame: .zero)
  private var node: RichBlockAgentCardNode?

  override var orderedTextSurfaces: [RichBlockTextSurface] {
    (node?.title == nil ? [] : [title]) + (node?.command == nil ? [] : [command])
  }

  init() {
    super.init(reuseKind: .agentCard)
    wantsLayer = true
    layer?.cornerRadius = RichBlockAgentCardMetrics.cornerRadius
    layer?.cornerCurve = .continuous
    commandBox.wantsLayer = true
    commandBox.layer?.cornerRadius = 6
    commandBox.layer?.cornerCurve = .continuous
    [commandBox, command, icon, title, titleLiteral, chip].forEach(addSubview)
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func apply(node: RichBlockLayoutPlan.Node, context: RichBlockRenderContext) {
    guard case let .agentCard(card) = node.kind else { return }
    self.node = card
    if let symbolName = card.symbolName {
      icon.isHidden = false
      icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
      icon.contentTintColor = context.palette.secondary
    } else {
      icon.isHidden = true
    }
    if let range = card.title {
      title.isHidden = false
      titleLiteral.isHidden = true
      title.apply(
        text: context.text(range, role: .heading(level: 4), isRTL: card.isRTL, maximumWidth: card.titleFrame?.width),
        linkColor: context.palette.link,
        onEntityClick: context.interactions.onTextEntityClick
      )
    } else if let literal = card.titleLiteral {
      title.isHidden = true
      titleLiteral.isHidden = false
      titleLiteral.stringValue = literal
      titleLiteral.textColor = context.palette.primary
      titleLiteral.alignment = card.isRTL ? .right : .left
    } else {
      title.isHidden = true
      titleLiteral.isHidden = true
    }
    if let value = card.chip {
      chip.isHidden = false
      chip.apply(value)
    } else {
      chip.isHidden = true
    }
    commandBox.isHidden = card.commandBoxFrame == nil
    if let range = card.command,
       let text = RichBlockLayoutPlanner.monospaceText(context.attributedText, range: range, color: context.palette.primary)
    {
      command.isHidden = false
      command.apply(text: text, linkColor: context.palette.link, onEntityClick: context.interactions.onTextEntityClick)
    } else {
      command.isHidden = true
    }
    setAccessibilityLabel([card.titleLiteral, card.title.map(context.plainString), card.chip?.text]
      .compactMap { $0 }.joined(separator: ", "))
    updateColors(context.palette)
    needsLayout = true
  }

  override func updateLayout(node: RichBlockLayoutPlan.Node) {
    guard case let .agentCard(card) = node.kind else { return }
    self.node = card
    needsLayout = true
  }

  override func layout() {
    super.layout()
    guard let node else { return }
    icon.frame = node.iconFrame ?? .zero
    title.frame = node.titleFrame ?? .zero
    titleLiteral.frame = node.titleFrame ?? .zero
    chip.frame = node.chip?.frame ?? .zero
    commandBox.frame = node.commandBoxFrame ?? .zero
    command.frame = node.commandFrame ?? .zero
  }

  private var palette: RichBlockPalette?

  private func updateColors(_ palette: RichBlockPalette) {
    self.palette = palette
    effectiveAppearance.performAsCurrentDrawingAppearance {
      // A next step is a quiet box; the others are outlined cards.
      let quiet = node?.kind == .nextStep
      layer?.backgroundColor = palette.subtleFill.cgColor
      layer?.borderWidth = quiet ? 0 : 1
      layer?.borderColor = palette.separator.cgColor
      commandBox.layer?.backgroundColor = palette.codeFill.cgColor
    }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    if let palette { updateColors(palette) }
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    node = nil
  }
}

// MARK: - Buttons

/// Loading and grants for a message action a block draws, read the same way as the
/// action rows under the message.
enum RichBlockInlineActionState {
  struct State {
    var isLoading: Bool
    var isEnabled: Bool
    var disabledReason: String?
  }

  /// A lookup by action id for the message in `context`, reading shared state once.
  @MainActor
  static func states(_ context: RichBlockRenderContext) -> (String) -> State {
    let message = context.relatedMessage
    let loading = MessageActionInteractionState.shared.loadingActionIds(
      peerId: message.peerId,
      messageId: message.messageId,
      rev: message.rev
    )
    let actions = BlockInlineActions.byID(message.actions)
    return { id in
      let isLoading = loading.contains(id)
      guard let action = actions[id] else { return State(isLoading: isLoading, isEnabled: false, disabledReason: nil) }
      let presentation = MessageActionPerformer.presentation(for: action, message: message)
      // A restricted action stays clickable, dimmed, so the tap can say why.
      return State(
        isLoading: isLoading,
        isEnabled: !isLoading && (presentation.isEnabled || presentation.disabledReason != nil),
        disabledReason: presentation.disabledReason
      )
    }
  }
}

/// A block's own buttons. Message actions run through the message's action pipeline, so
/// confirmation, grants and loading match the action rows under the message.
final class RichBlockAgentActionsNodeView: RichBlockRenderableView {
  private var buttons: [NSButton] = []
  private var spinners: [NSProgressIndicator] = []
  private let note = makeLabel(font: .systemFont(ofSize: NSFont.smallSystemFontSize))
  private let chip = RichBlockChipView(frame: .zero)
  private var node: RichBlockAgentActionsNode?
  private var effects: [RichBlockAgentActionsNode.Effect] = []
  private var context: RichBlockRenderContext?

  init() {
    super.init(reuseKind: .agentActions)
    addSubview(note)
    addSubview(chip)
    setAccessibilityElement(false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func apply(node: RichBlockLayoutPlan.Node, context: RichBlockRenderContext) {
    guard case let .agentActions(actions) = node.kind else { return }
    self.node = actions
    self.context = context
    effects = actions.buttons.map(\.effect)
    while buttons.count < actions.buttons.count {
      let button = NSButton(title: "", target: self, action: #selector(tap(_:)))
      button.bezelStyle = .rounded
      button.controlSize = .small
      button.font = RichBlockAgentCardMetrics.buttonFont
      addSubview(button)
      buttons.append(button)
      let spinner = NSProgressIndicator(frame: .zero)
      spinner.style = .spinning
      spinner.controlSize = .small
      spinner.isDisplayedWhenStopped = false
      addSubview(spinner)
      spinners.append(spinner)
    }
    for (index, button) in buttons.enumerated() {
      guard index < actions.buttons.count else {
        button.isHidden = true
        spinners[index].stopAnimation(nil)
        continue
      }
      let planned = actions.buttons[index]
      button.isHidden = false
      button.tag = index
      button.title = planned.title
      button.setAccessibilityLabel(planned.title)
      switch planned.style {
      case .primary:
        button.bezelStyle = .rounded
        button.isBordered = true
        button.bezelColor = .controlAccentColor
        button.keyEquivalent = ""
        button.contentTintColor = nil
      case .destructive:
        button.bezelStyle = .rounded
        button.isBordered = true
        button.bezelColor = nil
        button.contentTintColor = .systemRed
      case .standard:
        button.bezelStyle = .rounded
        button.isBordered = true
        button.bezelColor = nil
        button.contentTintColor = nil
      case .link:
        button.isBordered = false
        button.bezelColor = nil
        button.contentTintColor = context.palette.link
      }
    }
    if let value = actions.chip {
      chip.isHidden = false
      chip.apply(value)
    } else {
      chip.isHidden = true
    }
    if let text = actions.note {
      note.isHidden = false
      note.stringValue = text
      note.textColor = context.palette.secondary
      note.alignment = actions.isRTL ? .right : .left
    } else {
      note.isHidden = true
    }
    refreshLoadingState()
    needsLayout = true
  }

  /// Rereads which buttons wait on the server and which the viewer may use, after a tap,
  /// its answer or a grant change. A loading button shows a spinner in place of its title.
  func refreshLoadingState() {
    guard let node, let context else { return }
    let states = RichBlockInlineActionState.states(context)
    for (index, planned) in node.buttons.enumerated() where index < buttons.count {
      guard case let .action(id) = planned.effect else {
        buttons[index].isEnabled = true
        buttons[index].toolTip = nil
        buttons[index].alphaValue = 1
        spinners[index].stopAnimation(nil)
        continue
      }
      let state = states(id)
      buttons[index].isEnabled = state.isEnabled
      buttons[index].toolTip = state.disabledReason
      buttons[index].alphaValue = state.disabledReason == nil ? 1 : 0.5
      buttons[index].title = state.isLoading ? "" : planned.title
      if state.isLoading { spinners[index].startAnimation(nil) } else { spinners[index].stopAnimation(nil) }
    }
  }

  override func updateLayout(node: RichBlockLayoutPlan.Node) {
    guard case let .agentActions(actions) = node.kind else { return }
    // Geometry only; a change of buttons comes with a full apply.
    guard actions.buttons.map(\.effect) == effects else {
      if let context { apply(node: node, context: context) }
      return
    }
    self.node = actions
    needsLayout = true
  }

  override func layout() {
    super.layout()
    guard let node else { return }
    for (index, planned) in node.buttons.enumerated() where index < buttons.count {
      buttons[index].frame = planned.frame
      let side: CGFloat = 14
      spinners[index].frame = CGRect(
        x: planned.frame.midX - side / 2,
        y: planned.frame.midY - side / 2,
        width: side,
        height: side
      )
    }
    note.frame = node.noteFrame ?? .zero
    chip.frame = node.chip?.frame ?? .zero
  }

  @objc private func tap(_ sender: NSButton) {
    guard let context, effects.indices.contains(sender.tag) else { return }
    let message = context.relatedMessage
    switch effects[sender.tag] {
    case let .action(id):
      guard let action = BlockInlineActions.byID(message.actions)[id] else { return }
      context.interactions.onMessageAction(action)
    case let .toggle(path, expanded):
      context.interactions.onDisclosureToggle(path, expanded)
    case let .open(chatID, userID):
      var action = InlineProtocol.MessageAction()
      action.actionID = "open-thread"
      action.text = sender.title
      action.openLink = .with {
        $0.peerID = .with { peer in
          if let chatID { peer.chat = .with { $0.chatID = chatID } }
          else if let userID { peer.user = .with { $0.userID = userID } }
        }
      }
      context.interactions.onMessageAction(action)
    }
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    node = nil
    context = nil
    effects = []
  }
}

// MARK: - Review

final class RichBlockReviewNodeView: RichBlockRenderableView {
  private let icon = makeSymbolView(pointSize: 12)
  private let title = RichBlockTextSurface(frame: .zero)
  private let titleLiteral = makeLabel(font: RichBlockAgentCardMetrics.titleFont)
  private let chip = RichBlockChipView(frame: .zero)
  private let summary = RichBlockTextSurface(frame: .zero)
  private var rows: [FindingViews] = []
  private var node: RichBlockReviewNode?
  private var palette: RichBlockPalette?

  private final class FindingViews {
    let priority = RichBlockChipView(frame: .zero)
    let title = RichBlockTextSurface(frame: .zero)
    let location: NSTextField = {
      let label = makeLabel(font: RichBlockAgentCardMetrics.locationFont)
      // Long paths keep their file name.
      label.lineBreakMode = .byTruncatingMiddle
      return label
    }()
    let body = RichBlockTextSurface(frame: .zero)
    let outcome = makeSymbolView(pointSize: 12)
    let separator = NSView(frame: .zero)
    let action: NSButton = {
      let button = NSButton(title: "", target: nil, action: nil)
      button.bezelStyle = .rounded
      button.controlSize = .small
      button.font = RichBlockAgentCardMetrics.buttonFont
      return button
    }()

    var all: [NSView] { [separator, priority, title, location, body, outcome, action] }
  }

  private var context: RichBlockRenderContext?

  override var orderedTextSurfaces: [RichBlockTextSurface] {
    guard let node else { return [] }
    var surfaces: [RichBlockTextSurface] = node.title == nil ? [] : [title]
    if node.summary != nil { surfaces.append(summary) }
    for (index, finding) in node.findings.enumerated() where index < rows.count {
      surfaces.append(rows[index].title)
      if finding.body != nil { surfaces.append(rows[index].body) }
    }
    return surfaces
  }

  init() {
    super.init(reuseKind: .review)
    wantsLayer = true
    layer?.cornerRadius = RichBlockAgentCardMetrics.cornerRadius
    layer?.cornerCurve = .continuous
    layer?.borderWidth = 1
    [icon, title, titleLiteral, chip, summary].forEach(addSubview)
    setAccessibilityElement(true)
    setAccessibilityRole(.list)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func apply(node: RichBlockLayoutPlan.Node, context: RichBlockRenderContext) {
    guard case let .review(review) = node.kind else { return }
    self.node = review
    self.context = context
    icon.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: nil)
    icon.contentTintColor = context.palette.secondary
    if let range = review.title {
      title.isHidden = false
      titleLiteral.isHidden = true
      title.apply(
        text: context.text(range, role: .heading(level: 4), isRTL: review.isRTL, maximumWidth: review.titleFrame.width),
        linkColor: context.palette.link,
        onEntityClick: context.interactions.onTextEntityClick
      )
    } else {
      title.isHidden = true
      titleLiteral.isHidden = false
      titleLiteral.stringValue = review.titleLiteral ?? ""
      titleLiteral.textColor = context.palette.primary
    }
    if let value = review.chip {
      chip.isHidden = false
      chip.apply(value)
    } else {
      chip.isHidden = true
    }
    if let range = review.summary {
      summary.isHidden = false
      summary.apply(
        text: context.text(range, role: .paragraph, isRTL: review.isRTL, maximumWidth: review.summaryFrame?.width),
        linkColor: context.palette.link,
        onEntityClick: context.interactions.onTextEntityClick
      )
    } else {
      summary.isHidden = true
    }
    while rows.count < review.findings.count {
      let row = FindingViews()
      row.action.target = self
      row.action.action = #selector(runFindingAction(_:))
      row.separator.wantsLayer = true
      row.location.textColor = context.palette.secondary
      row.all.forEach(addSubview)
      rows.append(row)
    }
    for (index, row) in rows.enumerated() {
      guard index < review.findings.count else {
        row.all.forEach { $0.isHidden = true }
        continue
      }
      let finding = review.findings[index]
      row.separator.isHidden = finding.separatorY == nil
      if let priority = finding.priority {
        row.priority.isHidden = false
        row.priority.apply(priority)
      } else {
        row.priority.isHidden = true
      }
      row.title.isHidden = false
      row.title.apply(
        text: context.text(finding.title, role: .heading(level: 5), isRTL: review.isRTL, maximumWidth: finding.titleFrame.width),
        linkColor: context.palette.link,
        onEntityClick: context.interactions.onTextEntityClick
      )
      row.location.isHidden = finding.location == nil
      row.location.stringValue = finding.location ?? ""
      row.location.textColor = context.palette.secondary
      if let body = finding.body {
        row.body.isHidden = false
        row.body.apply(
          text: context.text(body, role: .footer, isRTL: review.isRTL, maximumWidth: finding.bodyFrame?.width),
          linkColor: context.palette.link,
          onEntityClick: context.interactions.onTextEntityClick
        )
      } else {
        row.body.isHidden = true
      }
      if finding.action != nil {
        row.action.isHidden = false
        row.action.tag = index
      } else {
        row.action.isHidden = true
      }
      if let symbol = finding.outcomeSymbol {
        row.outcome.isHidden = false
        row.outcome.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        row.outcome.contentTintColor = symbol.hasPrefix("checkmark") ? .systemGreen : context.palette.tertiary
      } else {
        row.outcome.isHidden = true
      }
    }
    setAccessibilityLabel([review.titleLiteral, review.title.map(context.plainString), review.chip?.text]
      .compactMap { $0 }.joined(separator: ", "))
    updateColors(context.palette)
    refreshLoadingState()
    needsLayout = true
  }

  /// Rereads loading and grants for the findings' buttons. A loading button reads "…".
  func refreshLoadingState() {
    guard let node, let context else { return }
    let states = RichBlockInlineActionState.states(context)
    for (index, finding) in node.findings.enumerated() where index < rows.count {
      guard let button = finding.action else { continue }
      guard case let .action(id) = button.effect else {
        rows[index].action.title = button.title
        rows[index].action.isEnabled = true
        continue
      }
      let state = states(id)
      rows[index].action.title = state.isLoading ? "…" : button.title
      rows[index].action.isEnabled = state.isEnabled
      rows[index].action.toolTip = state.disabledReason
      rows[index].action.alphaValue = state.disabledReason == nil ? 1 : 0.5
    }
  }

  override func updateLayout(node: RichBlockLayoutPlan.Node) {
    guard case let .review(review) = node.kind else { return }
    self.node = review
    needsLayout = true
  }

  override func layout() {
    super.layout()
    guard let node else { return }
    icon.frame = node.iconFrame
    title.frame = node.titleFrame
    titleLiteral.frame = node.titleFrame
    chip.frame = node.chip?.frame ?? .zero
    summary.frame = node.summaryFrame ?? .zero
    let inset = RichBlockAgentCardMetrics.horizontalInset
    for (index, finding) in node.findings.enumerated() where index < rows.count {
      let row = rows[index]
      row.separator.frame = finding.separatorY.map { CGRect(x: inset, y: $0, width: bounds.width - inset * 2, height: 1) } ?? .zero
      row.priority.frame = finding.priority?.frame ?? .zero
      row.title.frame = finding.titleFrame
      row.location.frame = finding.locationFrame ?? .zero
      row.body.frame = finding.bodyFrame ?? .zero
      row.outcome.frame = finding.outcomeFrame ?? .zero
      row.action.frame = finding.action?.frame ?? .zero
    }
  }

  @objc private func runFindingAction(_ sender: NSButton) {
    guard let node, let context, node.findings.indices.contains(sender.tag),
          case let .action(id)? = node.findings[sender.tag].action?.effect,
          let action = BlockInlineActions.byID(context.relatedMessage.actions)[id]
    else { return }
    context.interactions.onMessageAction(action)
  }

  private func updateColors(_ palette: RichBlockPalette) {
    self.palette = palette
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = palette.subtleFill.cgColor
      layer?.borderColor = palette.separator.cgColor
      for row in rows {
        row.separator.layer?.backgroundColor = palette.separator.cgColor
      }
    }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    if let palette { updateColors(palette) }
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    rows.forEach { $0.all.forEach { $0.removeFromSuperview() } }
    rows = []
    node = nil
  }
}

// MARK: - Prompt suggestions

/// Chips that put a prompt in this chat's composer. Nothing is sent until the viewer sends it.
final class RichBlockPromptChipsNodeView: RichBlockRenderableView {
  private var chips: [NSButton] = []
  private var labels: [RichBlockTextSurface] = []
  private var node: RichBlockPromptChipsNode?
  private var onCompose: ((String) -> Void)?
  private var palette: RichBlockPalette?

  override var orderedTextSurfaces: [RichBlockTextSurface] { Array(labels.prefix(node?.chips.count ?? 0)) }

  init() {
    super.init(reuseKind: .promptChips)
    setAccessibilityElement(false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func apply(node: RichBlockLayoutPlan.Node, context: RichBlockRenderContext) {
    guard case let .promptChips(prompts) = node.kind else { return }
    self.node = prompts
    onCompose = context.interactions.onCompose
    while chips.count < prompts.chips.count {
      let chip = NSButton(title: "", target: self, action: #selector(tap(_:)))
      chip.isBordered = false
      chip.wantsLayer = true
      chip.layer?.cornerRadius = RichBlockAgentCardMetrics.promptChipHeight / 2
      chip.layer?.cornerCurve = .continuous
      chip.layer?.borderWidth = 1
      addSubview(chip)
      chips.append(chip)
      let label = RichBlockTextSurface(frame: .zero)
      addSubview(label)
      labels.append(label)
    }
    for (index, chip) in chips.enumerated() {
      let visible = index < prompts.chips.count
      chip.isHidden = !visible
      labels[index].isHidden = !visible
      guard visible else { continue }
      let planned = prompts.chips[index]
      chip.tag = index
      chip.setAccessibilityLabel(context.plainString(planned.label))
      chip.setAccessibilityHelp(String(localized: "Puts this prompt in the message box"))
      chip.toolTip = planned.text
      labels[index].apply(
        text: context.text(planned.label, role: .paragraph, isRTL: prompts.isRTL, maximumWidth: planned.labelFrame.width),
        linkColor: context.palette.link,
        onEntityClick: { _, _ in false }
      )
    }
    updateColors(context.palette)
    needsLayout = true
  }

  override func updateLayout(node: RichBlockLayoutPlan.Node) {
    guard case let .promptChips(prompts) = node.kind else { return }
    self.node = prompts
    needsLayout = true
  }

  override func layout() {
    super.layout()
    guard let node else { return }
    for (index, planned) in node.chips.enumerated() where index < chips.count {
      chips[index].frame = planned.frame
      chips[index].layer?.cornerRadius = planned.frame.height / 2
      labels[index].frame = planned.labelFrame
    }
  }

  // Labels sit over the chips; clicks on them still post the prompt.
  override func hitTest(_ point: NSPoint) -> NSView? {
    let local = convert(point, from: superview)
    guard let node else { return super.hitTest(point) }
    for (index, planned) in node.chips.enumerated() where index < chips.count && planned.frame.contains(local) {
      return chips[index]
    }
    return super.hitTest(point)
  }

  @objc private func tap(_ sender: NSButton) {
    guard let node, node.chips.indices.contains(sender.tag) else { return }
    onCompose?(node.chips[sender.tag].text)
  }

  private func updateColors(_ palette: RichBlockPalette) {
    self.palette = palette
    effectiveAppearance.performAsCurrentDrawingAppearance {
      for chip in chips {
        chip.layer?.backgroundColor = palette.subtleFill.cgColor
        chip.layer?.borderColor = palette.separator.cgColor
      }
    }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    if let palette { updateColors(palette) }
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    node = nil
    onCompose = nil
  }
}
