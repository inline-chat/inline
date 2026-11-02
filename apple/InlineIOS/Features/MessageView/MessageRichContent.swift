import InlineKit
import InlineMessageLayout
import struct InlineProtocol.Block
import struct InlineProtocol.BlockCallout
import struct InlineProtocol.BlockContent
import struct InlineProtocol.BlockDiff
import struct InlineProtocol.BlockDisclosure
import struct InlineProtocol.BlockFields
import struct InlineProtocol.BlockForm
import struct InlineProtocol.BlockFormField
import struct InlineProtocol.BlockImage
import struct InlineProtocol.BlockList
import struct InlineProtocol.BlockMeter
import enum InlineProtocol.BlockStatus
import struct InlineProtocol.BlockSteps
import struct InlineProtocol.BlockTable
import struct InlineProtocol.BlockText
import struct InlineProtocol.MessageEntity
import TextProcessing
import UIKit

/// Turns a message's block content, or code fences in plain text, into the layout package's
/// rich block tree, styled from the message's body text.
struct MessageRichContent {
  let blocks: [RichBlock]
  /// Ready photos by image id.
  let photos: [String: PhotoInfo]

  struct Style {
    var baseFont: UIFont
    var textColor: UIColor
    var secondaryColor: UIColor
    var traits: UITraitCollection
  }

  /// Rich content for `message`, or nil when it has none or it is past the limits.
  ///
  /// `body` is the message text with entities applied; blocks index into it by range.
  static func make(
    for message: FullMessage,
    body: NSAttributedString,
    style: Style,
    expanded: [RichPath: Bool]
  ) -> MessageRichContent? {
    // Block ranges index the original text; a translation replaces it.
    if message.translationText == nil, let content = message.message.blockContentPayload?.content {
      var builder = Builder(body: body, style: style, expanded: expanded, root: content.blocks)
      guard builder.withinLimits(content), let blocks = builder.blocks(content.blocks, path: RichPath()),
            !blocks.isEmpty
      else { return nil }
      return MessageRichContent(blocks: blocks, photos: builder.photos)
    }
    return codeFences(in: message, body: body, style: style)
  }

  /// Plain text with code entities: the text between them becomes paragraphs.
  private static func codeFences(in message: FullMessage, body: NSAttributedString, style: Style) -> MessageRichContent? {
    let entities = (message.translationEntities ?? message.message.entities)?.entities ?? []
    let fences = entities.filter { $0.type == .pre }.sorted { $0.offset < $1.offset }
    guard !fences.isEmpty else { return nil }
    let builder = Builder(body: body, style: style, expanded: [:])
    let string = body.string as NSString
    var blocks: [RichBlock] = []
    var location = 0
    func paragraph(upTo end: Int) {
      guard end > location else { return }
      var range = NSRange(location: location, length: end - location)
      // Fences sit on their own lines; drop the newlines around them.
      while range.length > 0, string.character(at: range.location) == 10 { range.location += 1; range.length -= 1 }
      while range.length > 0, string.character(at: NSMaxRange(range) - 1) == 10 { range.length -= 1 }
      guard range.length > 0 else { return }
      blocks.append(.text(MessageText(body.attributedSubstring(from: range)), role: .paragraph))
    }
    for fence in fences {
      let range = NSRange(location: Int(fence.offset), length: Int(fence.length))
      guard range.location >= location, NSMaxRange(range) <= string.length else { return nil }
      paragraph(upTo: range.location)
      let language: String? = if case let .pre(pre)? = fence.entity, !pre.language.isEmpty { pre.language } else { nil }
      blocks.append(builder.code(string.substring(with: range), language: language))
      location = NSMaxRange(range)
    }
    paragraph(upTo: string.length)
    return MessageRichContent(blocks: blocks, photos: [:])
  }

  // MARK: - Builder

  private struct Builder {
    let body: NSAttributedString
    let style: Style
    let expanded: [RichPath: Bool]
    var photos: [String: PhotoInfo] = [:]
    /// The whole tree, for finding the text of blocks this build doesn't know.
    let root: [Block]
    var unknownRanges: [NSRange]?
    var nextUnknown = 0

    /// Diffs past this many lines say how many more there are.
    static let maximumDiffLines = 120
    /// Longer diff lines end in an ellipsis, which bounds the sideways scroll and the drawing.
    static let maximumDiffLineLength = 160

    init(body: NSAttributedString, style: Style, expanded: [RichPath: Bool], root: [Block] = []) {
      self.body = body
      self.style = style
      self.expanded = expanded
      self.root = root
    }

    /// Mirrors the server's limits, so a forged snapshot falls back to plain text.
    func withinLimits(_ content: BlockContent) -> Bool {
      var blocks = 0
      var cells = 0
      func visit(_ list: [Block], depth: Int) -> Bool {
        guard depth <= 16 else { return false }
        blocks += list.count
        guard blocks <= 1_024 else { return false }
        for block in list {
          switch block.kind {
          case let .table(table)?:
            cells += table.rows.reduce(0) { $0 + $1.cells.count }
            if cells > 256 { return false }
          case let .list(list)?:
            for item in list.items where !visit(item.children, depth: depth + 1) { return false }
          case let .quote(quote)?:
            if !visit(quote.children, depth: depth + 1) { return false }
          case let .disclosure(disclosure)?:
            if !visit(disclosure.children, depth: depth + 1) { return false }
          case let .callout(callout)?:
            if !visit(callout.children, depth: depth + 1) { return false }
          default:
            break
          }
        }
        return true
      }
      return visit(content.blocks, depth: 0)
    }

    mutating func blocks(_ list: [Block], path: RichPath) -> [RichBlock]? {
      var result: [RichBlock] = []
      for block in list {
        // Paths follow the built tree, as the planner's do, so a block with nothing to draw
        // doesn't shift the state of the disclosures after it.
        guard let converted = self.block(block, path: path.appending(result.count)) else { return nil }
        if case let .group(children) = converted, children.isEmpty { continue }
        result.append(converted)
      }
      return result
    }

    /// The block as rich content, or nil when it is malformed and the message should fall back
    /// to its flat text.
    mutating func block(_ block: Block, path: RichPath) -> RichBlock? {
      switch block.kind {
      case let .paragraph(text)?, let .math(text)?:
        return slice(text).map { .text($0, role: .paragraph) }
      case let .heading(heading)?:
        let level = Int(min(max(heading.level, 1), 6))
        // Medium weight and phone-sized: a little larger than the body, not much.
        let scale: CGFloat = [1.18, 1.1, 1.05, 1.0, 1.0, 1.0][level - 1]
        let font = UIFont.systemFont(ofSize: style.baseFont.pointSize * scale, weight: level == 1 ? .semibold : .medium)
        return slice(heading.text, font: font).map { .text($0, role: .heading(level: level)) }
      case let .footer(text)?:
        let font = style.baseFont.withSize(style.baseFont.pointSize * 0.82)
        return slice(text, font: font, color: style.secondaryColor).map { .text($0, role: .footer) }
      case let .code(code)?:
        guard let range = range(code.text) else { return nil }
        return self.code((body.string as NSString).substring(with: range), language: code.hasLanguage && !code.language.isEmpty ? code.language : nil)
      case let .list(list)?:
        guard list.kind == .ordered || list.kind == .unordered, !list.items.isEmpty else { return nil }
        let first = list.kind == .ordered && list.hasStart ? list.start : 1
        var items: [RichList.Item] = []
        for (index, item) in list.items.enumerated() {
          let marker = if item.hasChecked {
            item.checked ? "☑" : "☐"
          } else if list.kind == .ordered {
            "\(first + Int64(index))."
          } else {
            "•"
          }
          guard let children = blocks(item.children, path: path.appending(index)) else { return nil }
          items.append(.init(marker: styled(marker), children: children))
        }
        return .list(RichList(items: items, isRightToLeft: list.hasIsRtl && list.isRtl))
      case let .quote(quote)?:
        guard let children = blocks(quote.children, path: path) else { return nil }
        return .quote(children: children, isRightToLeft: quote.hasIsRtl && quote.isRtl)
      case let .table(table)?:
        var rows: [[MessageText]] = []
        for (rowIndex, row) in table.rows.enumerated() {
          var cells: [MessageText] = []
          for cell in row.cells {
            let font = rowIndex == 0 ? UIFont.systemFont(ofSize: style.baseFont.pointSize, weight: .semibold) : nil
            guard let text = slice(cell, font: font) else { return nil }
            cells.append(text)
          }
          rows.append(cells)
        }
        let alignments: [RichTable.Alignment] = table.alignments.map {
          switch $0 {
          case .center: .center
          case .right: .trailing
          default: .leading
          }
        }
        return .table(RichTable(rows: rows, alignments: alignments, isRightToLeft: table.hasIsRtl && table.isRtl))
      case .separator?:
        return .separator
      case let .image(image)?:
        return .image(richImage(image, path: path))
      case let .album(album)?:
        guard !album.images.isEmpty else { return nil }
        return .album(album.images.enumerated().map { richImage($1, path: path.appending($0)) })
      case let .disclosure(disclosure)?:
        guard disclosure.hasSummary, let summary = slice(disclosure.summary, color: style.secondaryColor, removesLinks: true),
              let children = blocks(disclosure.children, path: path)
        else { return nil }
        let symbol = Self.activitySymbol(disclosure.activityKind)
        let status = Self.status(disclosure.status)
        let meta = disclosure.hasMeta && disclosure.meta.length > 0
          ? slice(disclosure.meta, font: footerFont, color: style.secondaryColor.withAlphaComponent(0.72))
          : nil
        return .disclosure(RichDisclosure(
          summary: summary,
          children: children,
          isExpanded: expanded[path] ?? (disclosure.hasInitiallyOpen && disclosure.initiallyOpen),
          isInProgress: disclosure.kind == .progress || status == .running,
          hasActivityIcon: symbol != nil,
          isRightToLeft: disclosure.hasIsRtl && disclosure.isRtl,
          activitySymbol: symbol,
          status: status,
          meta: meta
        ))
      case let .diff(diff)?:
        return self.diff(diff)
      case let .fields(fields)?:
        return self.fields(fields)
      case let .steps(steps)?:
        return self.steps(steps)
      case let .callout(callout)?:
        guard let children = blocks(callout.children, path: path) else { return nil }
        let title = callout.hasTitle && callout.title.length > 0 ? slice(callout.title, font: titleFont) : nil
        let tone: RichCallout.Tone = switch callout.kind {
        case .success: .success
        case .warning: .warning
        case .error: .error
        default: .info
        }
        return .callout(RichCallout(tone: tone, title: title, children: children, isRightToLeft: callout.hasIsRtl && callout.isRtl))
      case let .meter(meter)?:
        return self.meter(meter)
      case let .form(form)?:
        return self.form(form)
      default:
        // A kind newer than this build: its text, found between its neighbors' ranges.
        return unknownText()
      }
    }

    // MARK: Agent blocks

    private var footerFont: UIFont { style.baseFont.withSize(style.baseFont.pointSize * 0.82) }
    private var titleFont: UIFont { UIFont.systemFont(ofSize: style.baseFont.pointSize, weight: .medium) }
    private var monospacedFont: UIFont {
      UIFont.monospacedSystemFont(ofSize: (style.baseFont.pointSize * 0.76).rounded(), weight: .regular)
    }

    static func status(_ status: BlockStatus) -> RichStatus? {
      switch status {
      case .pending: .pending
      case .running: .running
      case .waiting: .waiting
      case .done: .done
      case .failed: .failed
      case .cancelled: .cancelled
      case .unspecified, .UNRECOGNIZED: nil
      }
    }

    static func activitySymbol(_ kind: BlockDisclosure.ActivityKind) -> String? {
      switch kind {
      case .reasoning: "brain"
      case .explore, .search: "magnifyingglass"
      case .read: "doc.text"
      case .edit: "square.and.pencil"
      case .delete: "trash"
      case .move: "folder"
      case .command: "terminal"
      case .web: "globe"
      case .tool: "wrench.and.screwdriver"
      case .agent, .unspecified, .UNRECOGNIZED: nil
      }
    }

    /// Commands, paths and diffs read left to right whatever surrounds them.
    private func monospacedAttributes(color: UIColor) -> [NSAttributedString.Key: Any] {
      let paragraph = NSMutableParagraphStyle()
      paragraph.baseWritingDirection = .leftToRight
      return [.font: monospacedFont, .foregroundColor: color, .paragraphStyle: paragraph]
    }

    func diff(_ diff: BlockDiff) -> RichBlock? {
      guard let pathRange = range(diff.path) else { return nil }
      let string = body.string as NSString
      // A label draws the path, and a paragraph style here would replace its middle truncation.
      let path = ready(NSAttributedString(
        string: string.substring(with: pathRange),
        attributes: [.font: monospacedFont, .foregroundColor: style.textColor]
      ))
      let counts = NSMutableAttributedString()
      let countFont = UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
      if diff.hasAdditions {
        counts.append(NSAttributedString(string: "+\(diff.additions)", attributes: [.font: countFont, .foregroundColor: UIColor.systemGreen]))
      }
      if diff.hasDeletions {
        if counts.length > 0 { counts.append(NSAttributedString(string: " ", attributes: [.font: countFont])) }
        counts.append(NSAttributedString(string: "−\(diff.deletions)", attributes: [.font: countFont, .foregroundColor: UIColor.systemRed]))
      }
      let change: RichDiff.Change = switch diff.change {
      case .added: .added
      case .deleted: .deleted
      case .renamed: .renamed
      default: .modified
      }
      var richBody: MessageText?
      var footer: MessageText?
      var copyText = ""
      if diff.hasText, let bodyRange = range(diff.text), bodyRange.length > 0 {
        copyText = string.substring(with: bodyRange)
        richBody = diffBody(copyText, footer: &footer, senderTruncated: diff.hasTruncated && diff.truncated)
      }
      return .diff(RichDiff(
        path: path,
        counts: counts.length > 0 ? ready(counts) : nil,
        change: change,
        body: richBody,
        footer: footer,
        copyText: copyText
      ))
    }

    private func diffBody(_ source: String, footer: inout MessageText?, senderTruncated: Bool) -> MessageText {
      var lines = source.components(separatedBy: "\n")
      if lines.last?.isEmpty == true { lines.removeLast() }
      let hidden = max(0, lines.count - Self.maximumDiffLines)
      let result = NSMutableAttributedString()
      let attributes = monospacedAttributes(color: style.textColor)
      let hunkAttributes = monospacedAttributes(color: style.secondaryColor)
      for (index, line) in lines.prefix(Self.maximumDiffLines).enumerated() {
        let shown = line.utf16.count > Self.maximumDiffLineLength ? String(line.prefix(Self.maximumDiffLineLength)) + "…" : line
        let separator = index > 0 ? "\n" : ""
        result.append(NSAttributedString(string: separator + shown, attributes: line.hasPrefix("@@") ? hunkAttributes : attributes))
      }
      let note: String? = if hidden > 0 {
        String(localized: "\(hidden) more lines")
      } else if senderTruncated {
        String(localized: "Diff shortened by the agent")
      } else {
        nil
      }
      footer = note.map {
        ready(NSAttributedString(string: $0, attributes: [.font: UIFont.systemFont(ofSize: 11), .foregroundColor: style.secondaryColor]))
      }
      return ready(result)
    }

    func fields(_ fields: BlockFields) -> RichBlock? {
      guard !fields.fields.isEmpty, fields.fields.count <= 128 else { return nil }
      var rows: [RichFields.Row] = []
      for field in fields.fields {
        guard let label = slice(field.label, color: style.secondaryColor), let valueRange = range(field.value) else { return nil }
        let value: MessageText? = if field.monospace {
          ready(NSAttributedString(
            string: (body.string as NSString).substring(with: valueRange),
            attributes: monospacedAttributes(color: style.textColor)
          ))
        } else {
          slice(field.value)
        }
        guard let value else { return nil }
        rows.append(.init(label: label, value: value))
      }
      return .fields(RichFields(rows: rows, isRightToLeft: fields.hasIsRtl && fields.isRtl))
    }

    func steps(_ steps: BlockSteps) -> RichBlock? {
      guard !steps.steps.isEmpty, steps.steps.count <= 256 else { return nil }
      var items: [RichSteps.Step] = []
      for step in steps.steps {
        let status = Self.status(step.status) ?? .pending
        let isFinished = status == .done || status == .cancelled
        guard let text = slice(step.text, color: isFinished ? style.secondaryColor : nil) else { return nil }
        let detail = step.hasDetail && step.detail.length > 0
          ? slice(step.detail, font: footerFont, color: style.secondaryColor)
          : nil
        items.append(.init(text: text, detail: detail, status: status))
      }
      return .steps(RichSteps(steps: items, isRightToLeft: steps.hasIsRtl && steps.isRtl))
    }

    /// The label, then the meta as a footer. The bridge doesn't send meters, so text is enough.
    func meter(_ meter: BlockMeter) -> RichBlock? {
      guard let label = slice(meter.label) else { return nil }
      var children: [RichBlock] = [.text(label, role: .paragraph)]
      if meter.hasMeta, meter.meta.length > 0, let meta = slice(meter.meta, font: footerFont, color: style.secondaryColor) {
        children.append(.text(meta, role: .footer))
      }
      return .group(children)
    }

    /// A form's title, labels and choices as readable text. It has no controls here: an open
    /// form is answered by replying. A closed one shows its answers, and never a secret.
    func form(_ form: BlockForm) -> RichBlock? {
      var children: [RichBlock] = []
      let isRightToLeft = form.hasIsRtl && form.isRtl
      if form.hasTitle, form.title.length > 0 {
        guard let title = slice(form.title, font: titleFont) else { return nil }
        children.append(.text(title, role: .heading(level: 4)))
      }
      for field in form.fields {
        guard let label = slice(field.label) else { return nil }
        children.append(.text(label, role: .paragraph))
        if field.hasDescription_p, field.description_p.length > 0,
           let description = slice(field.description_p, font: footerFont, color: style.secondaryColor)
        {
          children.append(.text(description, role: .footer))
        }
        guard let answer = formAnswer(field, closed: form.closed, isRightToLeft: isRightToLeft) else { return nil }
        children += answer
      }
      return .group(children)
    }

    /// What goes under a form field's label: its choices, or a closed field's answer. Nil when
    /// the field is malformed.
    private func formAnswer(_ field: BlockFormField, closed: Bool, isRightToLeft: Bool) -> [RichBlock]? {
      switch field.kind {
      case let .select(select)?:
        var items: [RichList.Item] = []
        for option in select.options {
          guard let label = slice(option.label) else { return nil }
          var content: [RichBlock] = [.text(label, role: .paragraph)]
          if option.hasDescription_p, option.description_p.length > 0,
             let description = slice(option.description_p, font: footerFont, color: style.secondaryColor)
          {
            content.append(.text(description, role: .footer))
          }
          let marker = if select.defaultOptionIds.contains(option.optionID) {
            "☑"
          } else if select.multiple {
            "☐"
          } else {
            "•"
          }
          items.append(.init(marker: styled(marker), children: content))
        }
        if items.isEmpty { return [] }
        return [.list(RichList(items: items, isRightToLeft: isRightToLeft))]
      case let .text(text)?:
        guard closed, text.kind != .secret, text.hasDefaultValue, !text.defaultValue.isEmpty else { return [] }
        return [.text(styled(text.defaultValue), role: .paragraph)]
      case let .toggle(toggle)?:
        guard closed else { return [] }
        return [.text(styled(toggle.defaultValue ? String(localized: "On") : String(localized: "Off")), role: .paragraph)]
      case let .number(number)?:
        guard closed, number.hasDefaultValue else { return [] }
        let value = number.integer ? String(format: "%.0f", number.defaultValue) : "\(number.defaultValue)"
        return [.text(styled(value), role: .paragraph)]
      case nil:
        return []
      }
    }

    // MARK: Unknown kinds

    /// The next unknown block's text as a paragraph, or an empty group when it has none.
    mutating func unknownText() -> RichBlock {
      let ranges = unknownRanges ?? Self.unknownRanges(in: root, length: body.length)
      unknownRanges = ranges
      guard nextUnknown < ranges.count else { return .group([]) }
      var range = ranges[nextUnknown]
      nextUnknown += 1
      let string = body.string as NSString
      let whitespace = CharacterSet.whitespacesAndNewlines
      func isWhitespace(_ index: Int) -> Bool {
        guard let scalar = Unicode.Scalar(string.character(at: index)) else { return false }
        return whitespace.contains(scalar)
      }
      while range.length > 0, isWhitespace(range.location) { range.location += 1; range.length -= 1 }
      while range.length > 0, isWhitespace(NSMaxRange(range) - 1) { range.length -= 1 }
      guard range.length > 0 else { return .group([]) }
      return .text(MessageText(body.attributedSubstring(from: range)), role: .paragraph)
    }

    /// One range per unknown block, in tree order. Blocks write their text in order, so an
    /// unknown block's text is what lies between the known text before and after it.
    static func unknownRanges(in root: [Block], length: Int) -> [NSRange] {
      var ranges: [NSRange] = []
      var openIndex: Int?
      var cursor = 0
      func close(at end: Int) {
        guard let index = openIndex else { return }
        ranges[index].length = max(0, end - ranges[index].location)
        openIndex = nil
      }
      func visitText(_ text: BlockText) {
        guard text.offset >= 0, text.length > 0 else { return }
        let start = min(Int(text.offset), length)
        close(at: start)
        cursor = max(cursor, min(start + Int(text.length), length))
      }
      func visitBlocks(_ blocks: [Block], depth: Int) {
        guard depth <= 16 else { return }
        for block in blocks {
          switch block.kind {
          case let .paragraph(text)?, let .math(text)?, let .footer(text)?:
            visitText(text)
          case let .heading(heading)?:
            visitText(heading.text)
          case let .code(code)?:
            visitText(code.text)
          case let .list(list)?:
            for item in list.items { visitBlocks(item.children, depth: depth + 1) }
          case let .quote(quote)?:
            visitBlocks(quote.children, depth: depth + 1)
          case let .table(table)?:
            for row in table.rows {
              for cell in row.cells { visitText(cell) }
            }
          case .separator?, .image?, .album?:
            break
          case let .disclosure(disclosure)?:
            visitText(disclosure.summary)
            if disclosure.hasMeta { visitText(disclosure.meta) }
            visitBlocks(disclosure.children, depth: depth + 1)
          case let .diff(diff)?:
            visitText(diff.path)
            if diff.hasText { visitText(diff.text) }
          case let .fields(fields)?:
            for field in fields.fields {
              visitText(field.label)
              visitText(field.value)
            }
          case let .steps(steps)?:
            for step in steps.steps {
              visitText(step.text)
              if step.hasDetail { visitText(step.detail) }
            }
          case let .callout(callout)?:
            if callout.hasTitle { visitText(callout.title) }
            visitBlocks(callout.children, depth: depth + 1)
          case let .meter(meter)?:
            visitText(meter.label)
            if meter.hasMeta { visitText(meter.meta) }
          case let .form(form)?:
            if form.hasTitle { visitText(form.title) }
            for field in form.fields {
              visitText(field.label)
              if field.hasDescription_p { visitText(field.description_p) }
              if case let .select(select)? = field.kind {
                for option in select.options {
                  visitText(option.label)
                  if option.hasDescription_p { visitText(option.description_p) }
                }
              }
            }
          default:
            // Adjacent unknown blocks share one gap; the first takes it.
            ranges.append(NSRange(location: cursor, length: 0))
            if openIndex == nil { openIndex = ranges.count - 1 }
          }
        }
      }
      visitBlocks(root, depth: 0)
      close(at: length)
      return ranges
    }

    // MARK: Code

    func code(_ string: String, language: String?) -> RichBlock {
      let size = (style.baseFont.pointSize * 0.86).rounded()
      let font = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
      let text = ready(NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: style.textColor]))
      let lines = max(1, string.components(separatedBy: "\n").count)
      let numbers = language.map { _ in
        ready(NSAttributedString(
          string: (1 ... lines).map(String.init).joined(separator: "\n"),
          attributes: [.font: UIFont.monospacedDigitSystemFont(ofSize: size, weight: .regular), .foregroundColor: style.secondaryColor]
        ))
      }
      let label = language.map {
        ready(NSAttributedString(
          string: Self.displayLanguage($0),
          attributes: [.font: UIFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: style.secondaryColor]
        ))
      }
      return .code(RichCode(text: text, lineNumbers: numbers, languageLabel: label, language: language))
    }

    mutating func richImage(_ image: BlockImage, path: RichPath) -> RichImage {
      let id = path.description
      var size: CGSize?
      switch image.state {
      case let .pending(pending)?:
        if pending.hasDimensions { size = CGSize(width: CGFloat(pending.dimensions.width), height: CGFloat(pending.dimensions.height)) }
      case let .ready(photo)?:
        if let largest = photo.sizes.max(by: { Int($0.w) * Int($0.h) < Int($1.w) * Int($1.h) }) {
          size = CGSize(width: CGFloat(largest.w), height: CGFloat(largest.h))
        }
        let stored = Photo.from(proto: photo)
        let localID = stored.id ?? stored.photoId
        photos[id] = PhotoInfo(photo: stored, sizes: photo.sizes.map { PhotoSize.from(proto: $0, photoId: localID) })
      case let .unavailable(unavailable)?:
        if unavailable.hasDimensions {
          size = CGSize(width: CGFloat(unavailable.dimensions.width), height: CGFloat(unavailable.dimensions.height))
        }
      case nil:
        break
      }
      return RichImage(id: id, size: size)
    }

    // MARK: Text

    func range(_ text: BlockText) -> NSRange? {
      let range = NSRange(location: Int(text.offset), length: Int(text.length))
      guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= body.length else { return nil }
      return range
    }

    /// The block's text from the body, with its font replaced or its color changed for a role.
    func slice(_ text: BlockText, font: UIFont? = nil, color: UIColor? = nil, removesLinks: Bool = false) -> MessageText? {
      guard let range = range(text) else { return nil }
      let value = NSMutableAttributedString(attributedString: body.attributedSubstring(from: range))
      if removesLinks { LinkDetector.shared.removeLinks(from: value) }
      let full = NSRange(location: 0, length: value.length)
      if let font { value.addAttribute(.font, value: font, range: full) }
      if let color { value.addAttribute(.foregroundColor, value: color, range: full) }
      return font == nil && color == nil && !removesLinks ? MessageText(value) : ready(value)
    }

    func styled(_ string: String) -> MessageText {
      ready(NSAttributedString(string: string, attributes: [.font: style.baseFont, .foregroundColor: style.textColor]))
    }

    func ready(_ value: NSAttributedString) -> MessageText {
      MessageText(value.coreTextReady(for: style.traits))
    }

    static func displayLanguage(_ language: String) -> String {
      let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
      return switch trimmed.lowercased() {
      case "bash", "sh", "shell", "zsh": "Shell"
      case "c#", "csharp", "cs": "C#"
      case "c++", "cpp": "C++"
      case "css": "CSS"
      case "go", "golang": "Go"
      case "html": "HTML"
      case "javascript", "js": "JavaScript"
      case "json", "jsonc": "JSON"
      case "objective-c", "objc": "Objective-C"
      case "python", "py", "python3": "Python"
      case "ruby", "rb": "Ruby"
      case "rust", "rs": "Rust"
      case "sql", "postgres", "postgresql": "SQL"
      case "swift": "Swift"
      case "tsx": "TSX"
      case "typescript", "ts": "TypeScript"
      case "yaml", "yml": "YAML"
      default: trimmed.prefix(1).uppercased() + trimmed.dropFirst()
      }
    }
  }
}

/// Which disclosures people opened or closed, per message, for this app session.
@MainActor
final class MessageRichState {
  static let shared = MessageRichState()
  private var expanded: [Int64: [RichPath: Bool]] = [:]

  func expanded(for messageID: Int64) -> [RichPath: Bool] {
    expanded[messageID] ?? [:]
  }

  func set(_ isExpanded: Bool, at path: RichPath, for messageID: Int64) {
    expanded[messageID, default: [:]][path] = isExpanded
  }
}
