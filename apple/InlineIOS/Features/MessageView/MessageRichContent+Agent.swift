import Foundation
import InlineKit
import InlineMessageLayout
import struct InlineProtocol.Block
import struct InlineProtocol.BlockApproval
import struct InlineProtocol.BlockCallout
import enum InlineProtocol.BlockDecisionState
import struct InlineProtocol.BlockDiff
import struct InlineProtocol.BlockFields
import struct InlineProtocol.BlockMeter
import struct InlineProtocol.BlockNextStep
import struct InlineProtocol.BlockPlanProposal
import struct InlineProtocol.BlockPromptSuggestions
import struct InlineProtocol.BlockReview
import struct InlineProtocol.BlockReviewFinding
import enum InlineProtocol.BlockStatus
import struct InlineProtocol.BlockSteps
import struct InlineProtocol.BlockTaskSuggestion
import struct InlineProtocol.BlockText
import struct InlineProtocol.MessageAction
import UIKit

extension RichTone {
  /// The tone's color; `neutral` reads as secondary text.
  func color(accent: UIColor, secondary: UIColor) -> UIColor {
    switch self {
    case .neutral: secondary
    case .accent: accent
    case .success: .systemGreen
    case .warning: .systemOrange
    // System yellow is too light to read on a light chip; a deeper amber in light mode.
    case .caution: UIColor { $0.userInterfaceStyle == .dark ? .systemYellow : UIColor(red: 0.66, green: 0.47, blue: 0.0, alpha: 1) }
    case .critical: .systemRed
    }
  }
}

/// Agent blocks: each protocol kind becomes its own layout input, styled here from the body
/// text. A block that is malformed returns nil and shows its fallback text instead.
extension MessageRichContent.Builder {
  // MARK: Fonts

  private var size: CGFloat { style.baseFont.pointSize }
  private var titleFont: UIFont { .systemFont(ofSize: size * 0.94, weight: .semibold) }
  private var secondaryFont: UIFont { style.baseFont.withSize(size * 0.82) }
  private var chipFont: UIFont { .systemFont(ofSize: max(10, size * 0.68), weight: .semibold) }
  private var buttonFont: UIFont { .systemFont(ofSize: size * 0.86, weight: .medium) }
  private var monoFont: UIFont { .monospacedSystemFont(ofSize: (size * 0.8).rounded(), weight: .regular) }

  // MARK: Text

  private func plain(_ string: String, font: UIFont, color: UIColor) -> MessageText {
    ready(NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color]))
  }

  /// Monospaced, left to right: commands, paths, diffs.
  private func monospaced(_ string: String, font: UIFont? = nil, color: UIColor? = nil) -> MessageText {
    let paragraph = NSMutableParagraphStyle()
    paragraph.baseWritingDirection = .leftToRight
    paragraph.alignment = .left
    return ready(NSAttributedString(string: string, attributes: [
      .font: font ?? monoFont,
      .foregroundColor: color ?? style.textColor,
      .paragraphStyle: paragraph,
    ]))
  }

  private func string(_ text: BlockText) -> String? {
    range(text).map { (body.string as NSString).substring(with: $0) }
  }

  private func present(_ text: BlockText, when has: Bool = true) -> Bool {
    has && text.length > 0 && range(text) != nil
  }

  private func chip(_ text: String, tone: RichTone, symbol: String? = nil) -> RichChip {
    RichChip(text: plain(text, font: chipFont, color: tone.color(accent: style.accentColor, secondary: style.secondaryColor)), tone: tone, symbol: symbol)
  }

  /// Notes the whole block's text at its node, so a streaming message shows it once reached.
  private mutating func recordSpan(of block: Block, at path: RichPath) {
    if let span = BlockContentSpan.span(of: block) { sources[path] = span }
  }

  // MARK: Actions

  /// Buttons for the message actions a block lists, in order. Unknown or unusable IDs are
  /// skipped.
  private func buttons(_ ids: [String]) -> [RichButton] {
    ids.compactMap { id in
      guard let action = actions[id] else { return nil }
      return button(for: action)
    }
  }

  private func button(for action: MessageAction) -> RichButton? {
    let id = action.actionID.trimmingCharacters(in: .whitespacesAndNewlines)
    let title = action.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !id.isEmpty, !title.isEmpty, action.action != nil else { return nil }
    let buttonStyle: RichButton.Style = switch action.style {
    case .primary: .primary
    case .destructive: .destructive
    case .default, .UNRECOGNIZED: .standard
    }
    let color: UIColor = switch buttonStyle {
    case .primary: .white
    case .destructive: .systemRed
    case .standard, .suggestion: style.textColor
    }
    return RichButton(title: plain(title, font: buttonFont, color: color), tap: .action(id: id), style: buttonStyle)
  }

  private func userName(_ id: Int64) -> String? {
    guard id > 0, let user = ObjectCache.shared.getCachedUser(id: id)?.user else { return nil }
    let first = user.firstName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return first.isEmpty ? user.displayName : first
  }

  private enum DecisionSubject { case plan, approval, task }

  private func stateChip(_ state: BlockDecisionState, for subject: DecisionSubject) -> RichChip? {
    switch state {
    case .pending:
      subject == .task ? nil : chip(subject == .plan ? "Awaiting approval" : "Needs approval", tone: subject == .plan ? .accent : .warning)
    case .accepted:
      chip(subject == .task ? "Started" : "Approved", tone: .success)
    case .declined:
      chip(subject == .plan ? "Kept planning" : subject == .task ? "Dismissed" : "Denied", tone: .neutral)
    case .expired:
      chip("Expired", tone: .neutral)
    case .superseded:
      chip("Replaced", tone: .neutral)
    case .unspecified, .UNRECOGNIZED:
      nil
    }
  }

  private static func isDecided(_ state: BlockDecisionState) -> Bool {
    switch state {
    case .accepted, .declined, .expired, .superseded: true
    case .unspecified, .pending, .UNRECOGNIZED: false
    }
  }

  /// "Approved by Mo", "Kept planning": what replaces the buttons once decided.
  private func decisionLine(_ state: BlockDecisionState, by userID: Int64?, for subject: DecisionSubject) -> RichStatusLine? {
    let name = userID.flatMap(userName)
    let (text, symbol, tone): (String, String, RichTone)
    switch state {
    case .accepted:
      text = name.map { "Approved by \($0)" } ?? "Approved"
      (symbol, tone) = ("checkmark.circle.fill", .success)
    case .declined:
      text = subject == .plan
        ? name.map { "\($0) kept planning" } ?? "Kept planning"
        : name.map { "Denied by \($0)" } ?? "Denied"
      (symbol, tone) = ("xmark.circle", .neutral)
    case .expired:
      text = "Expired"
      (symbol, tone) = ("clock", .neutral)
    case .superseded:
      text = subject == .plan ? "Replaced by a newer plan" : "Replaced by a newer request"
      (symbol, tone) = ("arrow.triangle.2.circlepath", .neutral)
    case .unspecified, .pending, .UNRECOGNIZED:
      return nil
    }
    return RichStatusLine(symbol: .named(symbol, tone: tone), text: plain(text, font: secondaryFont, color: style.secondaryColor))
  }

  // MARK: Steps

  mutating func steps(_ steps: BlockSteps, block: Block, path: RichPath) -> RichBlock? {
    guard !steps.steps.isEmpty, steps.steps.count <= RichSteps.maximumItems else { return nil }
    var items: [RichSteps.Item] = []
    for step in steps.steps {
      let status: RichStatus? = switch step.status {
      case .pending: .pending
      case .running: .running
      case .waiting: .waiting
      case .done: .done
      case .failed: .failed
      case .cancelled: .cancelled
      case .unspecified, .UNRECOGNIZED: nil
      }
      let finished = status == .done || status == .cancelled
      guard let text = slice(step.text, color: finished ? style.secondaryColor : nil) else { return nil }
      let detail = present(step.detail, when: step.hasDetail)
        ? slice(step.detail, font: secondaryFont, color: style.secondaryColor)
        : nil
      items.append(.init(text: text, detail: detail, status: status))
    }
    recordSpan(of: block, at: path)
    return .steps(RichSteps(items: items, isRightToLeft: steps.hasIsRtl && steps.isRtl))
  }

  // MARK: Fields

  mutating func fields(_ fields: BlockFields, block: Block, path: RichPath) -> RichBlock? {
    guard !fields.fields.isEmpty, fields.fields.count <= RichFields.maximumRows else { return nil }
    var rows: [RichFields.Row] = []
    for field in fields.fields {
      guard let label = slice(field.label, color: style.secondaryColor) else { return nil }
      let value: MessageText? = field.monospace
        ? string(field.value).map { monospaced($0) }
        : slice(field.value)
      guard let value else { return nil }
      rows.append(.init(label: label, value: value))
    }
    recordSpan(of: block, at: path)
    return .fields(RichFields(rows: rows, isRightToLeft: fields.hasIsRtl && fields.isRtl))
  }

  // MARK: Callout

  mutating func callout(_ callout: BlockCallout, block: Block, path: RichPath) -> RichBlock? {
    let (tone, symbol): (RichTone, String) = switch callout.kind {
    case .success: (.success, "checkmark.circle.fill")
    case .warning: (.warning, "exclamationmark.triangle.fill")
    case .error: (.critical, "xmark.octagon.fill")
    case .info, .unspecified, .UNRECOGNIZED: (.accent, "info.circle.fill")
    }
    let title = present(callout.title, when: callout.hasTitle)
      ? slice(callout.title, font: .systemFont(ofSize: size, weight: .semibold))
      : nil
    guard title != nil || !callout.children.isEmpty,
          let children = blocks(callout.children, path: path, bounds: childBounds[path])
    else { return nil }
    recordSpan(of: block, at: path)
    return .callout(RichCallout(
      tone: tone,
      symbol: symbol,
      title: title,
      children: children,
      isRightToLeft: callout.hasIsRtl && callout.isRtl
    ))
  }

  // MARK: Meter

  mutating func meter(_ meter: BlockMeter, block: Block, path: RichPath) -> RichBlock? {
    guard meter.max > 0, meter.max.isFinite, meter.value.isFinite, let label = slice(meter.label) else { return nil }
    let meta = present(meter.meta, when: meter.hasMeta)
      ? slice(meter.meta, font: secondaryFont, color: style.secondaryColor)
      : nil
    let tone: RichTone = switch meter.tone {
    case .warning: .warning
    case .critical: .critical
    case .unspecified, .UNRECOGNIZED: .accent
    }
    recordSpan(of: block, at: path)
    return .meter(RichMeter(label: label, meta: meta, fraction: meter.value / meter.max, tone: tone))
  }

  // MARK: Diff

  /// Diff bodies show at most this many lines; the rest are counted in the footer.
  static let maximumDiffLines = 300

  mutating func diff(_ diff: BlockDiff, block: Block, path: RichPath) -> RichBlock? {
    guard let pathString = string(diff.path) else { return nil }
    let symbol = switch diff.change {
    case .added: "plus.square"
    case .deleted: "minus.square"
    case .renamed: "arrow.right.square"
    case .modified, .unspecified, .UNRECOGNIZED: "pencil.line"
    }
    var displayPath = pathString
    if diff.hasPreviousPath, let previous = string(diff.previousPath), !previous.isEmpty, previous != pathString {
      displayPath = "\(previous) → \(pathString)"
    }
    let counts = NSMutableAttributedString()
    let countFont = UIFont.monospacedDigitSystemFont(ofSize: (size * 0.72).rounded(), weight: .medium)
    if diff.hasAdditions {
      counts.append(NSAttributedString(string: "+\(diff.additions)", attributes: [.font: countFont, .foregroundColor: UIColor.systemGreen]))
    }
    if diff.hasDeletions {
      if counts.length > 0 { counts.append(NSAttributedString(string: " ", attributes: [.font: countFont])) }
      counts.append(NSAttributedString(string: "−\(diff.deletions)", attributes: [.font: countFont, .foregroundColor: UIColor.systemRed]))
    }
    var body: MessageText?
    var footer: String?
    if diff.hasText, let text = string(diff.text), !text.isEmpty {
      var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
      if lines.last?.isEmpty == true { lines.removeLast() }
      let shown = lines.prefix(Self.maximumDiffLines)
      body = monospaced(shown.joined(separator: "\n"), font: .monospacedSystemFont(ofSize: (size * 0.74).rounded(), weight: .regular))
      if lines.count > shown.count {
        footer = "\(lines.count - shown.count) more lines"
      } else if diff.hasTruncated, diff.truncated {
        footer = "Diff shortened by the agent"
      }
    }
    recordSpan(of: block, at: path)
    return .diff(RichDiff(
      symbol: symbol,
      path: monospaced(displayPath, font: .monospacedSystemFont(ofSize: (size * 0.76).rounded(), weight: .medium)),
      counts: counts.length > 0 ? ready(counts) : nil,
      body: body,
      footer: footer.map { plain($0, font: .systemFont(ofSize: (size * 0.68).rounded()), color: style.secondaryColor) }
    ))
  }

  // MARK: Plan proposal

  mutating func plan(_ plan: BlockPlanProposal, block: Block, path: RichPath) -> RichBlock? {
    let title = present(plan.title, when: plan.hasTitle)
      ? slice(plan.title, font: titleFont)
      : plain("Plan", font: titleFont, color: style.textColor)
    guard let title, let children = blocks(plan.children, path: path, bounds: childBounds[path]) else { return nil }
    let isExpanded = expanded[path] ?? false
    let decided = Self.isDecided(plan.state)
    inlineActionIDs.formUnion(plan.actionIds)
    recordSpan(of: block, at: path)
    return .planProposal(RichPlanProposal(
      symbol: "list.bullet.clipboard",
      title: title,
      state: stateChip(plan.state, for: .plan),
      children: children,
      collapsedHeight: ceil(style.baseFont.lineHeight * 12),
      isExpanded: isExpanded,
      toggle: RichToggle(
        label: plain(isExpanded ? "Show less" : "Show full plan", font: .systemFont(ofSize: size * 0.82, weight: .medium), color: style.accentColor),
        tap: .toggle(path, isExpanded: !isExpanded)
      ),
      buttons: decided ? [] : buttons(plan.actionIds),
      decision: decided ? decisionLine(plan.state, by: plan.hasDecidedByUserID ? plan.decidedByUserID : nil, for: .plan) : nil,
      isRightToLeft: plan.hasIsRtl && plan.isRtl
    ))
  }

  // MARK: Approval

  mutating func approval(_ approval: BlockApproval, block: Block, path: RichPath) -> RichBlock? {
    guard let title = slice(approval.title, font: titleFont), title.length > 0,
          let children = blocks(approval.children, path: path, bounds: childBounds[path])
    else { return nil }
    let symbol = switch approval.subject {
    case .command: "terminal"
    case .fileChange: "doc.text"
    case .tool: "wrench.and.screwdriver"
    case .permissions: "lock.shield"
    case .network: "network"
    case .unspecified, .UNRECOGNIZED: "hand.raised"
    }
    let command = present(approval.command, when: approval.hasCommand) ? string(approval.command).map { monospaced($0) } : nil
    var details: [MessageText] = []
    if present(approval.cwd, when: approval.hasCwd), let cwd = string(approval.cwd) {
      details.append(monospaced(cwd, font: .monospacedSystemFont(ofSize: (size * 0.72).rounded(), weight: .regular), color: style.secondaryColor))
    }
    if present(approval.reason, when: approval.hasReason), let reason = slice(approval.reason, font: secondaryFont, color: style.secondaryColor) {
      details.append(reason)
    }
    let isExpanded = expanded[path] ?? false
    let decided = Self.isDecided(approval.state)
    inlineActionIDs.formUnion(approval.actionIds)
    recordSpan(of: block, at: path)
    return .approval(RichApproval(
      symbol: symbol,
      title: title,
      state: stateChip(approval.state, for: .approval),
      command: command,
      details: details,
      children: children,
      isExpanded: isExpanded,
      toggle: children.isEmpty ? nil : RichToggle(
        label: plain(isExpanded ? "Hide details" : "Show details", font: .systemFont(ofSize: size * 0.82, weight: .medium), color: style.accentColor),
        tap: .toggle(path, isExpanded: !isExpanded)
      ),
      buttons: decided ? [] : buttons(approval.actionIds),
      decision: decided ? decisionLine(approval.state, by: approval.hasDecidedByUserID ? approval.decidedByUserID : nil, for: .approval) : nil,
      isRightToLeft: approval.hasIsRtl && approval.isRtl
    ))
  }

  // MARK: Review

  mutating func review(_ review: BlockReview, block: Block, path: RichPath) -> RichBlock? {
    guard review.findings.count <= RichReview.maximumFindings else { return nil }
    let title = present(review.title, when: review.hasTitle)
      ? slice(review.title, font: titleFont)
      : plain("Review", font: titleFont, color: style.textColor)
    guard let title else { return nil }
    let verdict: RichChip? = switch review.verdict {
    case .correct: chip("Looks good", tone: .success)
    case .incorrect: chip("Issues found", tone: .critical)
    case .needsAttention: chip("Needs attention", tone: .warning)
    case .unspecified, .UNRECOGNIZED: nil
    }
    let count = review.findings.count
    var findings: [RichReview.Finding] = []
    for (index, finding) in review.findings.enumerated() {
      guard let findingTitle = slice(finding.title), findingTitle.length > 0 else { return nil }
      let priority: RichChip? = switch finding.priority {
      case .p0: chip("P0", tone: .critical)
      case .p1: chip("P1", tone: .warning)
      case .p2: chip("P2", tone: .caution)
      case .p3: chip("P3", tone: .neutral)
      case .unspecified, .UNRECOGNIZED: nil
      }
      var location: MessageText?
      if present(finding.path, when: finding.hasPath), let file = string(finding.path) {
        // A long path keeps its file name, so the line number stays on a phone-width row.
        let components = file.split(separator: "/")
        var text = file.count > 36 && components.count > 1
          ? "…/" + (components.last.map(String.init) ?? file)
          : file
        if finding.hasStartLine, finding.startLine > 0 {
          text += ":\(finding.startLine)"
          if finding.hasEndLine, finding.endLine > finding.startLine { text += "-\(finding.endLine)" }
        }
        location = monospaced(text, font: .monospacedSystemFont(ofSize: (size * 0.72).rounded(), weight: .regular), color: style.secondaryColor)
      }
      let body = present(finding.body, when: finding.hasBody) ? slice(finding.body, font: secondaryFont, color: style.textColor) : nil
      let findingPath = path.appending(index)
      let isExpanded = expanded[findingPath] ?? false
      let outcome: RichSymbol? = switch finding.outcome {
      case .fixed: .named("checkmark.circle.fill", tone: .success)
      case .skipped: .named("arrow.uturn.right.circle", tone: .neutral)
      case .noChangeNeeded: .named("minus.circle", tone: .neutral)
      case .unspecified, .UNRECOGNIZED: nil
      }
      var button: RichButton?
      if finding.hasActionID, let action = actions[finding.actionID] {
        button = self.button(for: action)
        inlineActionIDs.insert(finding.actionID)
      }
      findings.append(.init(
        priority: priority,
        title: findingTitle,
        location: location,
        body: body,
        isExpanded: isExpanded,
        toggle: body == nil ? nil : .toggle(findingPath, isExpanded: !isExpanded),
        outcome: outcome,
        button: button
      ))
    }
    let summary = present(review.summary, when: review.hasSummary) ? slice(review.summary, font: secondaryFont, color: style.textColor) : nil
    recordSpan(of: block, at: path)
    return .review(RichReview(
      symbol: "checklist",
      title: title,
      verdict: verdict,
      count: count == 0 ? nil : plain(count == 1 ? "1 finding" : "\(count) findings", font: secondaryFont, color: style.secondaryColor),
      summary: summary,
      findings: findings,
      isRightToLeft: review.hasIsRtl && review.isRtl
    ))
  }

  // MARK: Task suggestion

  mutating func taskSuggestion(_ task: BlockTaskSuggestion, block: Block, path: RichPath) -> RichBlock? {
    guard let title = slice(task.title, font: titleFont), title.length > 0 else { return nil }
    let brief = present(task.brief, when: task.hasBrief) ? slice(task.brief, font: secondaryFont, color: style.secondaryColor) : nil
    let lapsed = task.hasExpiresAt && task.expiresAt > 0 && Date(timeIntervalSince1970: TimeInterval(task.expiresAt)) < Date()
    let state: BlockDecisionState = (task.state == .pending || task.state == .unspecified) && lapsed ? .expired : task.state
    var status: RichStatusLine?
    if state == .accepted, task.hasStartedPeer {
      let tap: RichTap? = switch task.startedPeer.type {
      case let .chat(chat)?: .openThread(id: chat.chatID)
      case let .user(user)?: .openUser(id: user.userID)
      default: nil
      }
      if let tap {
        status = RichStatusLine(
          symbol: .named("arrow.up.forward.circle", tone: .accent),
          text: plain("Open thread", font: .systemFont(ofSize: size * 0.86, weight: .medium), color: style.accentColor),
          tap: tap
        )
      }
    }
    inlineActionIDs.formUnion(task.actionIds)
    recordSpan(of: block, at: path)
    return .taskSuggestion(RichTaskSuggestion(
      symbol: "arrow.triangle.branch",
      title: title,
      state: stateChip(state, for: .task),
      brief: brief,
      buttons: Self.isDecided(state) ? [] : buttons(task.actionIds),
      status: status,
      isMuted: state == .expired || state == .superseded,
      isRightToLeft: task.hasIsRtl && task.isRtl
    ))
  }

  // MARK: Next step

  mutating func nextStep(_ step: BlockNextStep, block: Block, path: RichPath) -> RichBlock? {
    guard let recap = slice(step.recap, color: style.secondaryColor), recap.length > 0 else { return nil }
    let question = present(step.question, when: step.hasQuestion)
      ? slice(step.question, font: .systemFont(ofSize: size, weight: .semibold))
      : nil
    inlineActionIDs.formUnion(step.actionIds)
    recordSpan(of: block, at: path)
    return .nextStep(RichNextStep(
      recap: recap,
      question: question,
      waiting: step.blocking ? chip("Waiting on you", tone: .warning, symbol: "hand.raised.fill") : nil,
      buttons: buttons(step.actionIds),
      isRightToLeft: step.hasIsRtl && step.isRtl
    ))
  }

  // MARK: Prompt suggestions

  mutating func promptSuggestions(_ prompts: BlockPromptSuggestions, block: Block, path: RichPath) -> RichBlock? {
    guard prompts.prompts.count <= RichPromptSuggestions.maximumPrompts else { return nil }
    var buttons: [RichButton] = []
    for prompt in prompts.prompts {
      guard let label = slice(prompt.label, font: .systemFont(ofSize: size * 0.86), color: style.textColor),
            let labelString = string(prompt.label)
      else { return nil }
      let text = prompt.hasText && !prompt.text.isEmpty ? prompt.text : labelString
      guard case let .compose(composed) = MessageActionPresentation.composeIntent(text) else { continue }
      buttons.append(RichButton(title: label, tap: .compose(composed), style: .suggestion))
    }
    guard !buttons.isEmpty else { return nil }
    recordSpan(of: block, at: path)
    return .promptSuggestions(RichPromptSuggestions(prompts: buttons, isRightToLeft: prompts.hasIsRtl && prompts.isRtl))
  }
}
