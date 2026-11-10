import Foundation
import InlineProtocol

/// Base writing direction for rich blocks, decided per block from the text it covers.
///
/// A text reads right to left when it has more right-to-left words than left-to-right ones; a
/// tie goes to its first strong letter. Persian and Hebrew prose routinely opens with, or is
/// sprinkled with, Latin product names, identifiers and paths ("Claude Code حداقل ۲.۱ لازم دارد"),
/// which the first-strong rule alone (UAX #9 P2) reads as left to right. Same contract as
/// `server/src/modules/message/blockDirection.ts`.
public enum BlockContentDirection {
  /// Strong words found in a text. Containers add up their children's tallies.
  public struct Tally: Equatable, Sendable {
    public var rightToLeftWords = 0
    public var leftToRightWords = 0
    /// Direction of the first strong letter, nil when there are no letters.
    public var firstStrongIsRTL: Bool?

    public init() {}

    /// nil when the text has no letters, so the block inherits its container's direction.
    public var isRTL: Bool? {
      guard rightToLeftWords + leftToRightWords > 0 else { return nil }
      if rightToLeftWords != leftToRightWords { return rightToLeftWords > leftToRightWords }
      return firstStrongIsRTL
    }

    public mutating func add(_ other: Tally) {
      rightToLeftWords += other.rightToLeftWords
      leftToRightWords += other.leftToRightWords
      if firstStrongIsRTL == nil { firstStrongIsRTL = other.firstStrongIsRTL }
    }
  }

  public static func isRTL(_ text: String) -> Bool? {
    tally(text.unicodeScalars).isRTL
  }

  /// A word is a run of letters, with the marks and joiners Arabic-script words carry inside
  /// them; it counts for the direction of its first letter. Digits and punctuation are neutral.
  public static func tally(_ scalars: some Sequence<Unicode.Scalar>) -> Tally {
    var tally = Tally()
    var inWord = false
    for scalar in scalars {
      switch scalar.properties.generalCategory {
      case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .letterNumber:
        guard !inWord else { continue }
        inWord = true
        let isRTL = isRightToLeftLetter(scalar)
        if isRTL { tally.rightToLeftWords += 1 } else { tally.leftToRightWords += 1 }
        if tally.firstStrongIsRTL == nil { tally.firstStrongIsRTL = isRTL }
      case .nonspacingMark, .spacingMark, .enclosingMark:
        continue
      case .format where scalar.value == 0x200C || scalar.value == 0x200D:
        // ZWNJ/ZWJ sit inside Persian words such as "می‌شود".
        continue
      default:
        inWord = false
      }
    }
    return tally
  }

  static func isRightToLeftLetter(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x0590 ... 0x08FF, // Hebrew, Arabic, Syriac, Thaana, NKo, Samaritan, Mandaic, Arabic Extended
         0xFB1D ... 0xFDFF, // Hebrew and Arabic presentation forms A
         0xFE70 ... 0xFEFF, // Arabic presentation forms B
         0x10800 ... 0x10FFF, // historic right-to-left scripts
         0x1E800 ... 0x1EFFF: // Mende Kikakui, Adlam, Arabic mathematical symbols
      true
    default:
      false
    }
  }

  /// `content` with every text block's direction derived on this device from `text`, which
  /// the block ranges index in UTF-16.
  ///
  /// Prose leaves carry their own direction everywhere, list items included. A container
  /// (list, quote, table, disclosure, callout, agent blocks) takes the majority of the text
  /// inside it. Stored and older messages carry the server's first-letter flags; this replaces
  /// them so both read the same.
  public static func resolved(_ content: InlineProtocol.BlockContent, text: String) -> InlineProtocol.BlockContent {
    var resolver = Resolver(text: text as NSString)
    var content = content
    _ = resolver.resolve(&content.blocks)
    return content
  }

  /// Direction a block declares after `resolved(_:text:)`, nil for blocks without text.
  public static func declaredDirection(of block: InlineProtocol.Block) -> Bool? {
    switch block.kind {
    case let .paragraph(text)?, let .footer(text)?:
      text.hasIsRtl ? text.isRtl : nil
    case let .heading(heading)?:
      heading.text.hasIsRtl ? heading.text.isRtl : nil
    case let .list(list)?:
      list.hasIsRtl ? list.isRtl : nil
    case let .quote(quote)?:
      quote.hasIsRtl ? quote.isRtl : nil
    case let .table(table)?:
      table.hasIsRtl ? table.isRtl : nil
    case let .disclosure(disclosure)?:
      disclosure.hasIsRtl ? disclosure.isRtl : nil
    case let .callout(callout)?:
      callout.hasIsRtl ? callout.isRtl : nil
    case let .fields(fields)?:
      fields.hasIsRtl ? fields.isRtl : nil
    case let .steps(steps)?:
      steps.hasIsRtl ? steps.isRtl : nil
    case let .form(form)?:
      form.hasIsRtl ? form.isRtl : nil
    default:
      nil
    }
  }

  /// A list item reads in the direction of its first block that has text.
  public static func direction(of item: InlineProtocol.BlockListItem) -> Bool? {
    item.children.lazy.compactMap(declaredDirection(of:)).first
  }

  private struct Resolver {
    let text: NSString

    func tally(_ range: InlineProtocol.BlockText) -> Tally {
      let location = Int(range.offset)
      let length = Int(range.length)
      guard location >= 0, length > 0, location <= text.length, length <= text.length - location else {
        return Tally()
      }
      return BlockContentDirection.tally(text.substring(with: NSRange(location: location, length: length)).unicodeScalars)
    }

    func tally(_ ranges: [InlineProtocol.BlockText]) -> Tally {
      ranges.reduce(into: Tally()) { $0.add(tally($1)) }
    }

    /// Resolves `range` in place and returns its tally.
    func leaf(_ range: inout InlineProtocol.BlockText) -> Tally {
      let tally = tally(range)
      range.setDirection(tally.isRTL)
      return tally
    }

    mutating func resolve(_ blocks: inout [InlineProtocol.Block]) -> Tally {
      var total = Tally()
      for index in blocks.indices {
        total.add(resolve(&blocks[index]))
      }
      return total
    }

    mutating func resolve(_ block: inout InlineProtocol.Block) -> Tally {
      switch block.kind {
      case var .paragraph(text)?:
        let tally = leaf(&text)
        block.kind = .paragraph(text)
        return tally
      case var .footer(text)?:
        let tally = leaf(&text)
        block.kind = .footer(text)
        return tally
      case var .heading(heading)?:
        let tally = leaf(&heading.text)
        block.kind = .heading(heading)
        return tally
      case var .list(list)?:
        var total = Tally()
        for index in list.items.indices {
          total.add(resolve(&list.items[index].children))
        }
        list.setDirection(total.isRTL)
        block.kind = .list(list)
        return total
      case var .quote(quote)?:
        let total = resolve(&quote.children)
        quote.setDirection(total.isRTL)
        block.kind = .quote(quote)
        return total
      case var .table(table)?:
        let total = tally(table.rows.flatMap(\.cells))
        table.setDirection(total.isRTL)
        block.kind = .table(table)
        return total
      case var .disclosure(disclosure)?:
        // The summary row reads in its own direction; an empty one follows the children.
        let summary = disclosure.hasSummary ? tally(disclosure.summary) : Tally()
        var total = summary
        total.add(resolve(&disclosure.children))
        disclosure.setDirection(summary.isRTL ?? total.isRTL)
        block.kind = .disclosure(disclosure)
        return total
      case var .callout(callout)?:
        var total = callout.hasTitle ? tally(callout.title) : Tally()
        total.add(resolve(&callout.children))
        callout.setDirection(total.isRTL)
        block.kind = .callout(callout)
        return total
      case var .fields(fields)?:
        let total = tally(fields.fields.flatMap { [$0.label, $0.value] })
        fields.setDirection(total.isRTL)
        block.kind = .fields(fields)
        return total
      case var .steps(steps)?:
        let total = tally(steps.steps.flatMap { [$0.text] + ($0.hasDetail ? [$0.detail] : []) })
        steps.setDirection(total.isRTL)
        block.kind = .steps(steps)
        return total
      case var .form(form)?:
        var ranges = form.hasTitle ? [form.title] : []
        ranges += form.fields.map(\.label)
        let total = tally(ranges)
        form.setDirection(total.isRTL)
        block.kind = .form(form)
        return total
      default:
        // Code, math, diffs, meters, media and widgets render left to right and don't sway
        // the prose around them.
        return Tally()
      }
    }
  }
}

/// Blocks and texts that carry an optional `is_rtl`.
private protocol BlockDirectionCarrying {
  var isRtl: Bool { get set }
  mutating func clearIsRtl()
}

extension BlockDirectionCarrying {
  mutating func setDirection(_ isRTL: Bool?) {
    if let isRTL { isRtl = isRTL } else { clearIsRtl() }
  }
}

extension InlineProtocol.BlockText: BlockDirectionCarrying {}
extension InlineProtocol.BlockList: BlockDirectionCarrying {}
extension InlineProtocol.BlockQuote: BlockDirectionCarrying {}
extension InlineProtocol.BlockTable: BlockDirectionCarrying {}
extension InlineProtocol.BlockDisclosure: BlockDirectionCarrying {}
extension InlineProtocol.BlockCallout: BlockDirectionCarrying {}
extension InlineProtocol.BlockFields: BlockDirectionCarrying {}
extension InlineProtocol.BlockSteps: BlockDirectionCarrying {}
extension InlineProtocol.BlockForm: BlockDirectionCarrying {}
