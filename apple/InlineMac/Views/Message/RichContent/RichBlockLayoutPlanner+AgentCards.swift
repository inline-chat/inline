import AppKit
import InlineKit
import InlineProtocol

/// Shared metrics for the agent cards. Views read the same values, so planned and rendered
/// geometry never drift.
enum RichBlockAgentCardMetrics {
  static let horizontalInset: CGFloat = 12
  static let verticalInset: CGFloat = 10
  static let cornerRadius: CGFloat = 10
  static let iconSide: CGFloat = 15
  static let iconGap: CGFloat = 7
  static let headerGap: CGFloat = 8
  static let partSpacing: CGFloat = 6
  static let chipHeight: CGFloat = 18
  static let chipHorizontalPadding: CGFloat = 7
  static let buttonHeight: CGFloat = 24
  static let buttonHorizontalPadding: CGFloat = 11
  static let buttonSpacing: CGFloat = 6
  static let commandInset: CGFloat = 7
  static let findingSpacing: CGFloat = 8
  static let promptChipHeight: CGFloat = 26
  static let promptChipPadding: CGFloat = 11
  static let promptChipSpacing: CGFloat = 6
  /// Lines of a plan shown before "Show full plan".
  static let collapsedPlanLines: CGFloat = 12

  static var chipFont: NSFont { .systemFont(ofSize: 11, weight: .medium) }
  static var buttonFont: NSFont { .systemFont(ofSize: NSFont.systemFontSize(for: .small)) }
  static var titleFont: NSFont { .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold) }
  static var locationFont: NSFont { .monospacedSystemFont(ofSize: 11, weight: .regular) }

  static func width(of string: String, font: NSFont) -> CGFloat {
    ceil((string as NSString).size(withAttributes: [.font: font]).width)
  }

  /// A one-line label's width: its text plus the field's own padding.
  static func labelWidth(of string: String, font: NSFont) -> CGFloat {
    width(of: string, font: font) + 5
  }
}

extension RichBlockLayoutPlanner.Builder {
  private typealias Metrics = RichBlockAgentCardMetrics

  private struct CardFrame {
    var decorationIndex: Int
    var startY: CGFloat
    var contentX: CGFloat
    var contentWidth: CGFloat
  }

  private func validRange(_ text: InlineProtocol.BlockText) -> RichBlockTextRange? {
    let range = RichBlockTextRange(text)
    guard range.offset >= 0, range.length > 0, range.offset <= attributedText.length,
          range.length <= attributedText.length - range.offset
    else { return nil }
    return range
  }

  private func styled(_ range: RichBlockTextRange, role: RichBlockTextRole, isRTL: Bool, width: CGFloat) -> NSAttributedString? {
    RichBlockLayoutPlanner.styledText(
      attributedText,
      offset: range.offset,
      length: range.length,
      role: role,
      baseFontSize: baseFontSize,
      isRTL: isRTL,
      math: math,
      maximumWidth: width
    )
  }

  private func size(_ text: NSAttributedString, width: CGFloat) -> CGSize {
    let measurement = measureText(text, width: max(1, width))
    return CGSize(width: min(width, ceil(measurement.maxLineUsedWidth)), height: ceil(measurement.height))
  }

  private func chip(_ text: String, tone: RichBlockChipTone, trailingAt maxX: CGFloat, y: CGFloat, isRTL: Bool, containerX: CGFloat) -> RichBlockChip {
    let width = Metrics.width(of: text, font: Metrics.chipFont) + Metrics.chipHorizontalPadding * 2
    let x = isRTL ? containerX : maxX - width
    return RichBlockChip(text: text, tone: tone, frame: CGRect(x: x, y: y, width: width, height: Metrics.chipHeight))
  }

  // MARK: Card chrome

  /// Appends the card's chrome and header, and moves `height` below the header.
  private mutating func beginCard(
    _ kind: RichBlockAgentCardKind,
    path: BlockContentPath,
    symbolName: String?,
    title: RichBlockTextRange?,
    titleLiteral: String?,
    chip chipValue: (String, RichBlockChipTone)?,
    x: CGFloat,
    width: CGFloat,
    isRTL: Bool
  ) -> CardFrame {
    claimMaximumWidth()
    let startY = height
    let insetX = Metrics.horizontalInset
    let contentWidth = max(1, width - insetX * 2)
    let decorationIndex = nodes.count
    var card = RichBlockAgentCardNode(kind: kind, isRTL: isRTL)
    var headerHeight: CGFloat = 0
    if title != nil || titleLiteral != nil || symbolName != nil || chipValue != nil {
      let iconWidth = symbolName == nil ? 0 : Metrics.iconSide + Metrics.iconGap
      var chipWidth: CGFloat = 0
      if let chipValue {
        let value = chip(chipValue.0, tone: chipValue.1, trailingAt: width - insetX, y: 0, isRTL: isRTL, containerX: insetX)
        chipWidth = value.frame.width + Metrics.headerGap
        card.chip = value
      }
      let titleWidth = max(1, contentWidth - iconWidth - chipWidth)
      var titleSize = CGSize(width: 0, height: ceil(Metrics.titleFont.ascender - Metrics.titleFont.descender))
      if let title, let text = styled(title, role: .heading(level: 4), isRTL: isRTL, width: titleWidth) {
        titleSize = size(text, width: titleWidth)
        card.title = title
      } else if let titleLiteral {
        titleSize.width = min(titleWidth, Metrics.labelWidth(of: titleLiteral, font: Metrics.titleFont))
        card.titleLiteral = titleLiteral
      }
      headerHeight = max(titleSize.height, Metrics.chipHeight, symbolName == nil ? 0 : Metrics.iconSide)
      let top = Metrics.verticalInset
      if let symbolName {
        card.symbolName = symbolName
        card.iconFrame = CGRect(
          x: isRTL ? width - insetX - Metrics.iconSide : insetX,
          y: top + floor((min(headerHeight, titleSize.height + 2) - Metrics.iconSide) / 2),
          width: Metrics.iconSide,
          height: Metrics.iconSide
        )
      }
      card.titleFrame = CGRect(
        x: isRTL ? width - insetX - iconWidth - titleSize.width : insetX + iconWidth,
        y: top,
        width: titleSize.width,
        height: titleSize.height
      )
      if var value = card.chip {
        value.frame.origin.y = top + floor((min(headerHeight, titleSize.height) - Metrics.chipHeight) / 2)
        card.chip = value
      }
    }
    nodes.append(.init(
      path: path,
      frame: CGRect(x: x, y: startY, width: width, height: 0),
      kind: .agentCard(card)
    ))
    height = startY + Metrics.verticalInset + headerHeight
    return CardFrame(decorationIndex: decorationIndex, startY: startY, contentX: x + insetX, contentWidth: contentWidth)
  }

  /// Space before the next part of a card, unless it is the first thing in it.
  private mutating func separate(_ card: CardFrame) {
    if height > card.startY + Metrics.verticalInset + 0.5 { height += Metrics.partSpacing }
  }

  private mutating func endCard(_ card: CardFrame) {
    height += Metrics.verticalInset
    nodes[card.decorationIndex].frame.size.height = height - card.startY
    trailingTextLine = nil
  }

  /// A text part of a card that isn't a child block, as an ordinary selectable text node.
  private mutating func appendPart(
    _ text: InlineProtocol.BlockText,
    index: Int,
    role: RichBlockTextRole,
    path: BlockContentPath,
    card: CardFrame,
    isRTL: Bool
  ) -> Bool {
    guard validRange(text) != nil else { return true }
    var directed = text
    directed.isRtl = isRTL
    separate(card)
    return appendText(
      directed,
      role: role,
      path: BlockContentPath(path.components + [.part(index)]),
      x: card.contentX,
      width: card.contentWidth
    )
  }

  // MARK: Buttons

  private func decisionNote(_ state: RichBlockDecisionState, kind: RichBlockAgentCardKind) -> String? {
    switch (kind, state) {
    case (_, .pending): nil
    case (.planProposal, .accepted), (.approval, .accepted): String(localized: "Approved")
    case (.planProposal, .declined): String(localized: "Kept planning")
    case (.approval, .declined): String(localized: "Denied")
    case (.taskSuggestion, .accepted): String(localized: "Started")
    case (.taskSuggestion, .declined): String(localized: "Dismissed")
    case (.nextStep, .accepted), (.nextStep, .declined): String(localized: "Answered")
    case (_, .expired): String(localized: "Expired")
    case (_, .superseded): String(localized: "Replaced by a newer request")
    }
  }

  private func buttons(for actionIDs: [String]) -> [RichBlockAgentActionsNode.Button] {
    var seen: Set<String> = []
    return actionIDs.compactMap { id in
      guard seen.insert(id).inserted, let action = actionsByID[id], action.action != nil else { return nil }
      let title = action.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !title.isEmpty else { return nil }
      let style: RichBlockAgentActionsNode.Style = switch action.style {
      case .primary: .primary
      case .destructive: .destructive
      default: .standard
      }
      return .init(title: title, style: style, effect: .action(id), frame: .zero)
    }
  }

  /// Lays out buttons left to right (right to left for RTL), wrapping, followed by the note.
  private mutating func appendActions(
    _ input: [RichBlockAgentActionsNode.Button],
    note: String?,
    chip chipValue: (String, RichBlockChipTone)? = nil,
    path: BlockContentPath,
    card: CardFrame,
    isRTL: Bool
  ) {
    guard !input.isEmpty || note != nil || chipValue != nil else { return }
    separate(card)
    let x = card.contentX
    let width = card.contentWidth
    var buttons: [RichBlockAgentActionsNode.Button] = []
    var cursor: CGFloat = 0
    var y: CGFloat = 0
    for var button in input {
      let buttonWidth = min(width, Metrics.width(of: button.title, font: Metrics.buttonFont) + Metrics.buttonHorizontalPadding * 2)
      if cursor > 0, cursor + buttonWidth > width {
        cursor = 0
        y += Metrics.buttonHeight + Metrics.buttonSpacing
      }
      button.frame = CGRect(x: isRTL ? width - cursor - buttonWidth : cursor, y: y, width: buttonWidth, height: Metrics.buttonHeight)
      buttons.append(button)
      cursor += buttonWidth + Metrics.buttonSpacing
    }
    var nodeHeight = buttons.isEmpty ? 0 : y + Metrics.buttonHeight
    var trailingChip: RichBlockChip?
    if let chipValue {
      // Trails the last row of buttons when it fits, else takes a row of its own.
      let chipWidth = Metrics.width(of: chipValue.0, font: Metrics.chipFont) + Metrics.chipHorizontalPadding * 2
      let fits = buttons.isEmpty || cursor + chipWidth <= width
      let rowY = fits ? y : nodeHeight + Metrics.buttonSpacing
      let rowHeight = buttons.isEmpty ? Metrics.chipHeight : Metrics.buttonHeight
      trailingChip = RichBlockChip(
        text: chipValue.0,
        tone: chipValue.1,
        frame: CGRect(
          x: isRTL ? 0 : width - chipWidth,
          y: rowY + floor((rowHeight - Metrics.chipHeight) / 2),
          width: chipWidth,
          height: Metrics.chipHeight
        )
      )
      nodeHeight = max(nodeHeight, rowY + rowHeight)
    }
    var noteFrame: CGRect?
    if let note {
      let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
      let noteWidth = min(width, Metrics.labelWidth(of: note, font: font))
      let noteHeight = ceil(font.ascender - font.descender + font.leading)
      let noteY = buttons.isEmpty ? 0 : nodeHeight + Metrics.buttonSpacing
      noteFrame = CGRect(x: isRTL ? width - noteWidth : 0, y: noteY, width: noteWidth, height: noteHeight)
      nodeHeight = noteY + noteHeight
    }
    let frame = CGRect(x: x, y: height, width: width, height: nodeHeight)
    nodes.append(.init(
      path: BlockContentPath(path.components + [.part(99)]),
      frame: frame,
      kind: .agentActions(.init(buttons: buttons, note: note, noteFrame: noteFrame, chip: trailingChip, isRTL: isRTL))
    ))
    height = frame.maxY
  }

  // MARK: Plan proposal

  mutating func layout(
    planProposal plan: InlineProtocol.BlockPlanProposal,
    path: BlockContentPath,
    x: CGFloat,
    width: CGFloat,
    depth: Int,
    inheritedDirection: Bool?
  ) -> Bool {
    let isRTL = plan.hasIsRtl ? plan.isRtl : (inheritedDirection ?? false)
    let state = RichBlockDecisionState(plan.state)
    let chip: (String, RichBlockChipTone)? = switch state {
    case .pending: (String(localized: "Awaiting approval"), .accent)
    case .accepted: (String(localized: "Approved"), .success)
    case .declined: (String(localized: "Kept planning"), .neutral)
    case .expired, .superseded: (String(localized: state == .expired ? "Expired" : "Replaced"), .neutral)
    }
    let title = plan.hasTitle ? validRange(plan.title) : nil
    let card = beginCard(
      .planProposal,
      path: path,
      symbolName: "list.bullet.clipboard",
      title: title,
      titleLiteral: title == nil ? String(localized: "Plan") : nil,
      chip: chip,
      x: x,
      width: width,
      isRTL: isRTL
    )
    var isLong = false
    let expanded = disclosureOverrides[path] ?? false
    if !plan.children.isEmpty {
      separate(card)
      let bodyStart = height
      let beforeBody = checkpoint()
      let claimedBeforeBody = claimedActionIDs
      let firstChild = nodes.count
      guard layout(
        blocks: plan.children,
        parent: path,
        x: card.contentX,
        width: card.contentWidth,
        depth: depth,
        inheritedDirection: isRTL,
        fullBleedContainer: nil,
        bounds: childBounds[path]
      ) else { return false }
      // A long plan shows the first blocks that fit, with "Show full plan".
      let limit = ceil(baseFontSize * 1.35 * Metrics.collapsedPlanLines)
      isLong = height - bodyStart > limit + baseFontSize * 3
      if isLong, !expanded {
        var fitting = 0
        for index in plan.children.indices {
          let prefix = path.components + [.block(index)]
          let bottom = nodes[firstChild...]
            .filter { $0.path.components.starts(with: prefix) }
            .map(\.frame.maxY)
            .max() ?? bodyStart
          guard bottom <= bodyStart + limit else { break }
          fitting = index + 1
        }
        // The block that crosses the limit keeps what fits of it when it is a list, so a
        // plan that is one long list still previews its first steps.
        var shown = Array(plan.children.prefix(fitting))
        if fitting < plan.children.count, case var .list(list)? = plan.children[fitting].kind {
          var items = 0
          for itemIndex in list.items.indices {
            let prefix = path.components + [.block(fitting), .listItem(itemIndex)]
            let bottom = nodes[firstChild...]
              .filter { $0.path.components.starts(with: prefix) }
              .map(\.frame.maxY)
              .max() ?? bodyStart
            guard bottom <= bodyStart + limit else { break }
            items = itemIndex + 1
          }
          if items > 0 {
            list.items = Array(list.items.prefix(items))
            var partial = plan.children[fitting]
            partial.kind = .list(list)
            shown.append(partial)
          }
        }
        // A first block taller than the limit still shows, whole.
        if shown.isEmpty { shown = [plan.children[0]] }
        // The shown blocks may claim text only up to the first hidden one.
        let hiddenStart = plan.children.dropFirst(shown.count).lazy.compactMap { BlockContentSpan.span(of: $0) }.first?.lowerBound
        let shownBounds = childBounds[path].flatMap { inner in
          let upper = min(inner.upperBound, hiddenStart ?? inner.upperBound)
          return inner.lowerBound < upper ? inner.lowerBound ..< upper : nil
        }
        restore(beforeBody, claimedActionIDs: claimedBeforeBody)
        guard layout(
          blocks: shown,
          parent: path,
          x: card.contentX,
          width: card.contentWidth,
          depth: depth,
          inheritedDirection: isRTL,
          fullBleedContainer: nil,
          bounds: shownBounds
        ) else { return false }
      }
    }
    var actions = state == .pending ? buttons(for: plan.actionIds) : []
    if isLong {
      actions.append(.init(
        title: expanded ? String(localized: "Show less") : String(localized: "Show full plan"),
        style: .link,
        effect: .toggle(path, expanded: !expanded),
        frame: .zero
      ))
    }
    appendActions(actions, note: decisionNote(state, kind: .planProposal), path: path, card: card, isRTL: isRTL)
    claimedActionIDs.formUnion(plan.actionIds)
    endCard(card)
    return true
  }

  // MARK: Approval

  mutating func layout(
    approval: InlineProtocol.BlockApproval,
    path: BlockContentPath,
    x: CGFloat,
    width: CGFloat,
    depth: Int,
    inheritedDirection: Bool?
  ) -> Bool {
    let isRTL = approval.hasIsRtl ? approval.isRtl : (inheritedDirection ?? false)
    let state = RichBlockDecisionState(approval.state)
    let symbol = switch approval.subject {
    case .command: "terminal"
    case .fileChange: "doc.badge.plus"
    case .tool: "wrench.and.screwdriver"
    case .permissions: "lock.shield"
    case .network: "network"
    default: "hand.raised"
    }
    let chip: (String, RichBlockChipTone)? = switch state {
    case .pending: (String(localized: "Needs approval"), .warning)
    case .accepted: (String(localized: "Approved"), .success)
    case .declined: (String(localized: "Denied"), .danger)
    case .expired: (String(localized: "Expired"), .neutral)
    case .superseded: (String(localized: "Replaced"), .neutral)
    }
    let title = validRange(approval.title)
    let card = beginCard(
      .approval,
      path: path,
      symbolName: symbol,
      title: title,
      titleLiteral: title == nil ? String(localized: "Approval") : nil,
      chip: chip,
      x: x,
      width: width,
      isRTL: isRTL
    )
    if approval.hasCommand, let command = validRange(approval.command),
       let text = RichBlockLayoutPlanner.monospaceText(attributedText, range: command)
    {
      separate(card)
      let inset = Metrics.commandInset
      let textWidth = max(1, card.contentWidth - inset * 2)
      let measured = size(text, width: textWidth)
      let box = CGRect(x: Metrics.horizontalInset, y: height - card.startY, width: card.contentWidth, height: measured.height + inset * 2)
      if case var .agentCard(node) = nodes[card.decorationIndex].kind {
        node.command = command
        node.commandBoxFrame = box
        node.commandFrame = CGRect(x: box.minX + inset, y: box.minY + inset, width: measured.width, height: measured.height)
        nodes[card.decorationIndex].kind = .agentCard(node)
      }
      height += box.height
    }
    if approval.hasCwd, !appendPart(approval.cwd, index: 1, role: .footer, path: path, card: card, isRTL: false) { return false }
    if approval.hasReason, !appendPart(approval.reason, index: 2, role: .paragraph, path: path, card: card, isRTL: isRTL) { return false }
    if !approval.children.isEmpty {
      separate(card)
      guard layout(
        blocks: approval.children,
        parent: path,
        x: card.contentX,
        width: card.contentWidth,
        depth: depth,
        inheritedDirection: isRTL,
        fullBleedContainer: nil,
        bounds: childBounds[path]
      ) else { return false }
    }
    appendActions(
      state == .pending ? buttons(for: approval.actionIds) : [],
      note: decisionNote(state, kind: .approval),
      path: path,
      card: card,
      isRTL: isRTL
    )
    claimedActionIDs.formUnion(approval.actionIds)
    endCard(card)
    return true
  }

  // MARK: Task suggestion

  mutating func layout(
    taskSuggestion task: InlineProtocol.BlockTaskSuggestion,
    path: BlockContentPath,
    x: CGFloat,
    width: CGFloat,
    inheritedDirection: Bool?
  ) -> Bool {
    guard let title = validRange(task.title) else { return false }
    let isRTL = task.hasIsRtl ? task.isRtl : (inheritedDirection ?? false)
    var state = RichBlockDecisionState(task.state)
    if state == .pending, task.hasExpiresAt, task.expiresAt > 0, Date().timeIntervalSince1970 > TimeInterval(task.expiresAt) {
      state = .expired
    }
    let chip: (String, RichBlockChipTone)? = switch state {
    case .pending: nil
    case .accepted: (String(localized: "Started"), .success)
    case .declined: (String(localized: "Dismissed"), .neutral)
    case .expired: (String(localized: "Expired"), .neutral)
    case .superseded: (String(localized: "Replaced"), .neutral)
    }
    let card = beginCard(
      .taskSuggestion,
      path: path,
      symbolName: "arrow.triangle.branch",
      title: title,
      titleLiteral: nil,
      chip: chip,
      x: x,
      width: width,
      isRTL: isRTL
    )
    if task.hasBrief, !appendPart(task.brief, index: 0, role: .paragraph, path: path, card: card, isRTL: isRTL) { return false }
    var actions = state == .pending ? buttons(for: task.actionIds) : []
    if state == .accepted, task.hasStartedPeer {
      let peer = task.startedPeer
      let effect: RichBlockAgentActionsNode.Effect? = switch peer.type {
      case let .chat(chat)?: .open(chatID: chat.chatID, userID: nil)
      case let .user(user)?: .open(chatID: nil, userID: user.userID)
      case nil: nil
      }
      if let effect {
        actions.append(.init(title: String(localized: "Open thread"), style: .standard, effect: effect, frame: .zero))
      }
    }
    appendActions(actions, note: nil, path: path, card: card, isRTL: isRTL)
    claimedActionIDs.formUnion(task.actionIds)
    endCard(card)
    return true
  }

  // MARK: Next step

  mutating func layout(
    nextStep step: InlineProtocol.BlockNextStep,
    path: BlockContentPath,
    x: CGFloat,
    width: CGFloat,
    inheritedDirection: Bool?
  ) -> Bool {
    guard validRange(step.recap) != nil else { return false }
    let isRTL = step.hasIsRtl ? step.isRtl : (inheritedDirection ?? false)
    let card = beginCard(
      .nextStep,
      path: path,
      symbolName: nil,
      title: nil,
      titleLiteral: nil,
      chip: nil,
      x: x,
      width: width,
      isRTL: isRTL
    )
    guard appendPart(step.recap, index: 0, role: .paragraph, path: path, card: card, isRTL: isRTL) else { return false }
    if step.hasQuestion, !appendPart(step.question, index: 1, role: .heading(level: 4), path: path, card: card, isRTL: isRTL) {
      return false
    }
    appendActions(
      buttons(for: step.actionIds),
      note: nil,
      chip: step.blocking ? (String(localized: "Waiting on you"), .warning) : nil,
      path: path,
      card: card,
      isRTL: isRTL
    )
    claimedActionIDs.formUnion(step.actionIds)
    endCard(card)
    return true
  }

  // MARK: Review

  mutating func appendReview(
    _ review: InlineProtocol.BlockReview,
    path: BlockContentPath,
    x: CGFloat,
    width: CGFloat,
    inheritedDirection: Bool?
  ) -> Bool {
    guard review.findings.count <= 200 else { return false }
    claimMaximumWidth()
    let isRTL = review.hasIsRtl ? review.isRtl : (inheritedDirection ?? false)
    let insetX = Metrics.horizontalInset
    let contentWidth = max(1, width - insetX * 2)
    var y = Metrics.verticalInset

    // Header: icon, title, verdict chip.
    let count = review.findings.count
    let countText = count == 0
      ? String(localized: "No findings")
      : count == 1 ? String(localized: "1 finding") : String(localized: "\(count) findings")
    let chipValue: (String, RichBlockChipTone) = switch review.verdict {
    case .correct: (count == 0 ? String(localized: "Looks good") : countText, .success)
    case .incorrect: (countText, .danger)
    case .needsAttention: (countText, .warning)
    default: (countText, count == 0 ? .success : .neutral)
    }
    let verdictChip = chip(chipValue.0, tone: chipValue.1, trailingAt: width - insetX, y: y, isRTL: isRTL, containerX: insetX)
    let iconWidth = Metrics.iconSide + Metrics.iconGap
    let titleWidth = max(1, contentWidth - iconWidth - verdictChip.frame.width - Metrics.headerGap)
    let title = review.hasTitle ? validRange(review.title) : nil
    var titleSize = CGSize(width: 0, height: ceil(Metrics.titleFont.ascender - Metrics.titleFont.descender))
    var titleLiteral: String?
    if let title, let text = styled(title, role: .heading(level: 4), isRTL: isRTL, width: titleWidth) {
      titleSize = size(text, width: titleWidth)
    } else {
      titleLiteral = String(localized: "Review")
      titleSize.width = Metrics.labelWidth(of: titleLiteral!, font: Metrics.titleFont)
    }
    let headerHeight = max(titleSize.height, Metrics.chipHeight)
    let iconFrame = CGRect(
      x: isRTL ? width - insetX - Metrics.iconSide : insetX,
      y: y + floor((titleSize.height - Metrics.iconSide) / 2),
      width: Metrics.iconSide,
      height: Metrics.iconSide
    )
    let titleFrame = CGRect(
      x: isRTL ? width - insetX - iconWidth - titleSize.width : insetX + iconWidth,
      y: y,
      width: titleSize.width,
      height: titleSize.height
    )
    var placedChip = verdictChip
    placedChip.frame.origin.y = y + floor((titleSize.height - Metrics.chipHeight) / 2)
    y += headerHeight + Metrics.partSpacing

    var summaryFrame: CGRect?
    let summary = review.hasSummary ? validRange(review.summary) : nil
    if let summary, let text = styled(summary, role: .paragraph, isRTL: isRTL, width: contentWidth) {
      let measured = size(text, width: contentWidth)
      summaryFrame = CGRect(x: isRTL ? width - insetX - measured.width : insetX, y: y, width: measured.width, height: measured.height)
      y += measured.height + Metrics.partSpacing
    }

    // Findings: priority chip, title, location, body, outcome.
    var findings: [RichBlockReviewNode.Finding] = []
    for (index, finding) in review.findings.enumerated() {
      guard let findingTitle = validRange(finding.title) else { return false }
      var planned = RichBlockReviewNode.Finding(title: findingTitle, titleFrame: .zero)
      if index > 0 || summaryFrame != nil {
        planned.separatorY = y
        y += Metrics.findingSpacing
      }
      var leading: CGFloat = 0
      let priority: (String, RichBlockChipTone)? = switch finding.priority {
      case .p0: ("P0", .danger)
      case .p1: ("P1", .warning)
      case .p2: ("P2", .accent)
      case .p3: ("P3", .neutral)
      default: nil
      }
      if let priority {
        let chipWidth = Metrics.width(of: priority.0, font: Metrics.chipFont) + Metrics.chipHorizontalPadding * 2
        planned.priority = RichBlockChip(
          text: priority.0,
          tone: priority.1,
          frame: CGRect(x: isRTL ? width - insetX - chipWidth : insetX, y: y, width: chipWidth, height: Metrics.chipHeight)
        )
        leading = chipWidth + Metrics.iconGap
      }
      let outcome: String? = switch finding.outcome {
      case .fixed: "checkmark.circle.fill"
      case .skipped: "minus.circle"
      case .noChangeNeeded: "circle"
      default: nil
      }
      let trailing: CGFloat = outcome == nil ? 0 : Metrics.iconSide + Metrics.iconGap
      let textWidth = max(1, contentWidth - leading - trailing)
      let textX = isRTL ? insetX + trailing : insetX + leading
      guard let titleText = styled(findingTitle, role: .heading(level: 5), isRTL: isRTL, width: textWidth) else { return false }
      let titleMeasured = size(titleText, width: textWidth)
      planned.titleFrame = CGRect(
        x: isRTL ? textX + textWidth - titleMeasured.width : textX,
        y: y,
        width: titleMeasured.width,
        height: titleMeasured.height
      )
      if let outcome {
        planned.outcomeSymbol = outcome
        planned.outcomeFrame = CGRect(
          x: isRTL ? insetX : width - insetX - Metrics.iconSide,
          y: y + 1,
          width: Metrics.iconSide,
          height: Metrics.iconSide
        )
      }
      y += max(titleMeasured.height, priority == nil ? 0 : Metrics.chipHeight)
      if finding.hasPath, let pathRange = validRange(finding.path) {
        var location = (attributedText.string as NSString).substring(with: NSRange(location: pathRange.offset, length: pathRange.length))
        if finding.hasStartLine, finding.startLine > 0 {
          location += ":\(finding.startLine)"
          if finding.hasEndLine, finding.endLine > finding.startLine { location += "-\(finding.endLine)" }
        }
        let locationWidth = min(textWidth, Metrics.labelWidth(of: location, font: Metrics.locationFont))
        let locationHeight = ceil(Metrics.locationFont.ascender - Metrics.locationFont.descender) + 2
        planned.location = location
        planned.locationFrame = CGRect(x: isRTL ? textX + textWidth - locationWidth : textX, y: y + 2, width: locationWidth, height: locationHeight)
        y += locationHeight + 2
      }
      if finding.hasBody, let body = validRange(finding.body),
         let text = styled(body, role: .footer, isRTL: isRTL, width: textWidth)
      {
        let measured = size(text, width: textWidth)
        planned.body = body
        planned.bodyFrame = CGRect(x: isRTL ? textX + textWidth - measured.width : textX, y: y + 2, width: measured.width, height: measured.height)
        y += measured.height + 2
      }
      if finding.hasActionID, var button = buttons(for: [finding.actionID]).first {
        let buttonWidth = min(textWidth, Metrics.width(of: button.title, font: Metrics.buttonFont) + Metrics.buttonHorizontalPadding * 2)
        button.frame = CGRect(x: isRTL ? textX + textWidth - buttonWidth : textX, y: y + 4, width: buttonWidth, height: Metrics.buttonHeight)
        planned.action = button
        claimedActionIDs.insert(finding.actionID)
        y += Metrics.buttonHeight + 4
      }
      findings.append(planned)
    }
    y += Metrics.verticalInset
    let frame = CGRect(x: x, y: height, width: width, height: ceil(y))
    nodes.append(.init(path: path, frame: frame, kind: .review(.init(
      iconFrame: iconFrame,
      title: titleLiteral == nil ? title : nil,
      titleLiteral: titleLiteral,
      titleFrame: titleFrame,
      chip: placedChip,
      summary: summaryFrame == nil ? nil : summary,
      summaryFrame: summaryFrame,
      findings: findings,
      isRTL: isRTL
    ))))
    height = frame.maxY
    trailingTextLine = nil
    return true
  }

  // MARK: Prompt suggestions

  mutating func appendPromptChips(
    _ prompts: InlineProtocol.BlockPromptSuggestions,
    path: BlockContentPath,
    x: CGFloat,
    width: CGFloat,
    inheritedDirection: Bool?
  ) -> Bool {
    guard !prompts.prompts.isEmpty, prompts.prompts.count <= 8 else { return false }
    let isRTL = prompts.hasIsRtl ? prompts.isRtl : (inheritedDirection ?? false)
    let padding = Metrics.promptChipPadding
    var chips: [RichBlockPromptChipsNode.Chip] = []
    var cursor: CGFloat = 0
    var y: CGFloat = 0
    var usedWidth: CGFloat = 0
    let source = attributedText.string as NSString
    for prompt in prompts.prompts {
      guard let label = validRange(prompt.label),
            let text = styled(label, role: .paragraph, isRTL: isRTL, width: max(1, width - padding * 2))
      else { return false }
      let measured = size(text, width: max(1, width - padding * 2))
      let chipWidth = min(width, measured.width + padding * 2)
      let chipHeight = max(Metrics.promptChipHeight, measured.height + 8)
      if cursor > 0, cursor + chipWidth > width {
        cursor = 0
        y = (chips.map(\.frame.maxY).max() ?? y) + Metrics.promptChipSpacing
      }
      let frame = CGRect(x: isRTL ? width - cursor - chipWidth : cursor, y: y, width: chipWidth, height: chipHeight)
      let composerText = prompt.hasText && !prompt.text.isEmpty
        ? prompt.text
        : source.substring(with: NSRange(location: label.offset, length: label.length))
      chips.append(.init(
        label: label,
        text: composerText,
        frame: frame,
        labelFrame: CGRect(x: frame.minX + padding, y: frame.minY + floor((chipHeight - measured.height) / 2), width: measured.width, height: measured.height)
      ))
      cursor += chipWidth + Metrics.promptChipSpacing
      usedWidth = max(usedWidth, cursor - Metrics.promptChipSpacing)
    }
    let nodeHeight = chips.map(\.frame.maxY).max() ?? 0
    let frame = CGRect(x: x, y: height, width: isRTL ? width : min(width, ceil(usedWidth)), height: nodeHeight)
    nodes.append(.init(path: path, frame: CGRect(x: x, y: height, width: width, height: nodeHeight), kind: .promptChips(.init(chips: chips, isRTL: isRTL))))
    recordMeasuredFrame(frame)
    height += nodeHeight
    return true
  }
}
