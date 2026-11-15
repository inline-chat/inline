import Foundation
import InlineProtocol

/// Where each block reads from in the message text, and what a client shows for a block it
/// can't draw.
///
/// Every block's text is a UTF-16 range into `Message.message`, which stays the complete
/// fallback. A client that can't draw one block shows that block's text as a paragraph and
/// draws the rest normally. A kind newer than this build arrives with no kind at all, so it
/// shows the text between its drawable neighbours.
public enum BlockContentSpan {
  /// The UTF-16 range a block covers, children included, or nil when it carries no text.
  ///
  /// The switch is exhaustive on purpose: a new block kind fails the build here until its
  /// text ranges are listed.
  public static func span(of block: Block) -> Range<Int>? {
    var span = Accumulator()
    switch block.kind {
    case let .paragraph(text)?, let .footer(text)?, let .math(text)?:
      span.add(text)
    case let .heading(heading)?:
      span.add(heading.text)
    case let .code(code)?:
      span.add(code.text)
    case let .list(list)?:
      for item in list.items { span.add(item.children) }
    case .separator?:
      break
    case let .image(image)?:
      span.add(image.alt)
    case let .album(album)?:
      for image in album.images { span.add(image.alt) }
    case let .disclosure(disclosure)?:
      span.add(disclosure.summary)
      span.add(disclosure.meta)
      span.add(disclosure.children)
    case let .quote(quote)?:
      span.add(quote.children)
    case let .table(table)?:
      for row in table.rows { for cell in row.cells { span.add(cell) } }
    case let .diff(diff)?:
      span.add(diff.path)
      span.add(diff.previousPath)
      span.add(diff.text)
    case let .fields(fields)?:
      for field in fields.fields {
        span.add(field.label)
        span.add(field.value)
      }
    case let .steps(steps)?:
      for step in steps.steps {
        span.add(step.text)
        span.add(step.detail)
      }
    case let .callout(callout)?:
      span.add(callout.title)
      span.add(callout.children)
    case let .meter(meter)?:
      span.add(meter.label)
      span.add(meter.meta)
    case let .form(form)?:
      span.add(form.title)
      for field in form.fields {
        span.add(field.header)
        span.add(field.label)
        span.add(field.description_p)
        for option in field.select.options {
          span.add(option.label)
          span.add(option.description_p)
          span.add(option.preview)
        }
      }
    case let .widget(widget)?:
      span.add(widget.title)
      for image in widget.images { span.add(image.alt) }
    case let .planProposal(plan)?:
      span.add(plan.title)
      span.add(plan.children)
    case let .approval(approval)?:
      span.add(approval.title)
      span.add(approval.command)
      span.add(approval.cwd)
      span.add(approval.reason)
      span.add(approval.children)
    case let .review(review)?:
      span.add(review.title)
      span.add(review.summary)
      for finding in review.findings {
        span.add(finding.title)
        span.add(finding.body)
        span.add(finding.path)
      }
    case let .taskSuggestion(task)?:
      span.add(task.title)
      span.add(task.brief)
    case let .nextStep(step)?:
      span.add(step.recap)
      span.add(step.question)
    case let .promptSuggestions(prompts)?:
      for prompt in prompts.prompts { span.add(prompt.label) }
    case nil:
      break
    }
    return span.range
  }

  /// The text to show for `blocks[index]` when the client can't draw it, trimmed of
  /// surrounding whitespace, or nil when there is none.
  ///
  /// A known kind shows its own span. A kind this build doesn't know shows the text between
  /// the nearest siblings that have a span; `bounds` stands in for a missing sibling, and
  /// without bounds such a block shows nothing. A run of unknown kinds shares one gap, shown
  /// once by the first of them.
  public static func fallbackRange(
    at index: Int,
    in blocks: [Block],
    text: NSString,
    bounds: Range<Int>? = nil
  ) -> Range<Int>? {
    guard blocks.indices.contains(index) else { return nil }
    let range: Range<Int>?
    if blocks[index].kind != nil {
      range = span(of: blocks[index])
    } else {
      if index > 0, blocks[index - 1].kind == nil { return nil }
      let previous = blocks[..<index].reversed().lazy.compactMap { span(of: $0) }.first
      let next = blocks[(index + 1)...].lazy.compactMap { span(of: $0) }.first
      guard let lower = previous?.upperBound ?? bounds?.lowerBound,
            let upper = next?.lowerBound ?? bounds?.upperBound,
            lower < upper
      else { return nil }
      range = lower ..< upper
    }
    guard let range else { return nil }
    return trimmed(range, in: text)
  }

  /// The text the children of `blocks[index]` may claim, for an unknown kind first or last
  /// among them: after the container's own leading text (title, summary, command…) and the
  /// sibling before it, up to the sibling after it. `bounds` stands in for missing siblings.
  /// Nil for blocks that hold no child blocks.
  public static func childBounds(at index: Int, in blocks: [Block], bounds: Range<Int>?) -> Range<Int>? {
    guard blocks.indices.contains(index) else { return nil }
    var own = Accumulator()
    switch blocks[index].kind {
    case let .planProposal(plan)?:
      own.add(plan.title)
    case let .approval(approval)?:
      own.add(approval.title)
      own.add(approval.command)
      own.add(approval.cwd)
      own.add(approval.reason)
    case let .callout(callout)?:
      own.add(callout.title)
    case let .disclosure(disclosure)?:
      own.add(disclosure.summary)
      own.add(disclosure.meta)
    case .quote?, .list?:
      // A list's items take their bounds from it (`itemBounds`).
      break
    default:
      return nil
    }
    let previous = blocks[..<index].reversed().lazy.compactMap { span(of: $0) }.first
    let next = blocks[(index + 1)...].lazy.compactMap { span(of: $0) }.first
    let lowers = [own.range?.upperBound, previous?.upperBound, bounds?.lowerBound].compactMap { $0 }
    guard let lower = lowers.max(), let upper = next?.lowerBound ?? bounds?.upperBound, lower < upper
    else { return nil }
    return lower ..< upper
  }

  /// The text the children of `list.items[index]` may claim, for an unknown kind first or
  /// last among them: after the item before it, up to the item after it. `bounds` is the
  /// list's own (`childBounds` of the list) and stands in for missing items.
  public static func itemBounds(at index: Int, in list: BlockList, bounds: Range<Int>?) -> Range<Int>? {
    guard list.items.indices.contains(index) else { return nil }
    func span(_ item: BlockListItem) -> Range<Int>? {
      var span = Accumulator()
      span.add(item.children)
      return span.range
    }
    let previous = list.items[..<index].reversed().lazy.compactMap(span).first
    let next = list.items[(index + 1)...].lazy.compactMap(span).first
    let lowers = [previous?.upperBound, bounds?.lowerBound].compactMap { $0 }
    guard let lower = lowers.max(), let upper = next?.lowerBound ?? bounds?.upperBound, lower < upper
    else { return nil }
    return lower ..< upper
  }

  /// `range` clamped to the text and without leading or trailing whitespace and newlines.
  static func trimmed(_ range: Range<Int>, in text: NSString) -> Range<Int>? {
    var lower = max(0, range.lowerBound)
    var upper = min(text.length, range.upperBound)
    let whitespace = CharacterSet.whitespacesAndNewlines
    func isSpace(_ index: Int) -> Bool {
      guard let scalar = Unicode.Scalar(text.character(at: index)) else { return false }
      return whitespace.contains(scalar)
    }
    while lower < upper, isSpace(lower) { lower += 1 }
    while upper > lower, isSpace(upper - 1) { upper -= 1 }
    return lower < upper ? lower ..< upper : nil
  }

  private struct Accumulator {
    var range: Range<Int>?

    mutating func add(_ text: BlockText) {
      // Ranges past any real text (malformed or hostile) are ignored rather than trapping.
      guard text.length > 0, text.offset >= 0, text.offset <= Int64(Int32.max), text.length <= Int64(Int32.max)
      else { return }
      let lower = Int(text.offset)
      let upper = lower + Int(text.length)
      range = range.map { min($0.lowerBound, lower) ..< max($0.upperBound, upper) } ?? lower ..< upper
    }

    mutating func add(_ blocks: [Block]) {
      for block in blocks {
        guard let child = BlockContentSpan.span(of: block) else { continue }
        range = range.map { min($0.lowerBound, child.lowerBound) ..< max($0.upperBound, child.upperBound) } ?? child
      }
    }
  }
}
