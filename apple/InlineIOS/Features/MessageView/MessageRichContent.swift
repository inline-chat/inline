import InlineKit
import InlineMessageLayout
import struct InlineProtocol.Block
import struct InlineProtocol.BlockContent
import struct InlineProtocol.BlockDisclosure
import struct InlineProtocol.BlockImage
import struct InlineProtocol.BlockList
import struct InlineProtocol.BlockTable
import struct InlineProtocol.BlockText
import struct InlineProtocol.MessageEntity
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
      var builder = Builder(body: body, style: style, expanded: expanded)
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

    init(body: NSAttributedString, style: Style, expanded: [RichPath: Bool]) {
      self.body = body
      self.style = style
      self.expanded = expanded
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
      for (index, block) in list.enumerated() {
        guard let converted = self.block(block, path: path.appending(index)) else { return nil }
        result.append(converted)
      }
      return result
    }

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
        guard disclosure.hasSummary, let summary = slice(disclosure.summary, color: style.secondaryColor),
              let children = blocks(disclosure.children, path: path)
        else { return nil }
        let activity = disclosure.activityKind
        return .disclosure(RichDisclosure(
          summary: summary,
          children: children,
          isExpanded: expanded[path] ?? (disclosure.hasInitiallyOpen && disclosure.initiallyOpen),
          isInProgress: disclosure.kind == .progress,
          hasActivityIcon: activity != .unspecified && activity != .agent,
          isRightToLeft: disclosure.hasIsRtl && disclosure.isRtl
        ))
      default:
        // Kinds this view doesn't draw yet, such as agent steps and forms, fall back to the
        // message's flat text, as the protocol asks of clients that don't know a kind.
        return nil
      }
    }

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
    func slice(_ text: BlockText, font: UIFont? = nil, color: UIColor? = nil) -> MessageText? {
      guard let range = range(text) else { return nil }
      let value = NSMutableAttributedString(attributedString: body.attributedSubstring(from: range))
      let full = NSRange(location: 0, length: value.length)
      if let font { value.addAttribute(.font, value: font, range: full) }
      if let color { value.addAttribute(.foregroundColor, value: color, range: full) }
      return font == nil && color == nil ? MessageText(value) : ready(value)
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
