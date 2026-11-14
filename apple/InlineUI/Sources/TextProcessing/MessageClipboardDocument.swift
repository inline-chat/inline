import Foundation
import InlineProtocol

/// Message content selected for copy, kept as blocks so every clipboard flavor (plain text,
/// Markdown, HTML, RTF and Inline's composer payload) renders natively from one source.
public struct MessageClipboardDocument: Equatable, Sendable {
  public struct Text: Equatable, Sendable {
    public var string: String
    /// Inline formatting, with UTF-16 offsets into `string`.
    public var entities: [MessageEntity]

    public init(string: String, entities: [MessageEntity] = []) {
      self.string = string
      self.entities = entities
    }

    /// From rendered message text: math back to its source, fonts and code markers to entities.
    @MainActor
    public init(rendered: NSAttributedString) {
      let range = NSRange(location: 0, length: rendered.length)
      let source = RichTextMath.sourceAttributedText(rendered, range: range) ?? rendered
      let extracted = ProcessEntities.fromAttributedString(
        MessageMarkdown.normalizedText(source),
        parseMarkdown: false
      )
      self.init(string: extracted.text, entities: extracted.entities.entities)
    }

    var isBlank: Bool { string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  }

  public enum ListMarker: Equatable, Sendable {
    case bullet
    case ordered(Int)

    /// "3." or "3)" is ordered; anything else (•, ◦, -) is a bullet.
    public init(rendered: String) {
      let trimmed = rendered.trimmingCharacters(in: .whitespaces)
      let digits = trimmed.prefix(while: \.isNumber)
      if let number = Int(digits), trimmed.count == digits.count + 1, trimmed.last == "." || trimmed.last == ")" {
        self = .ordered(number)
      } else {
        self = .bullet
      }
    }
  }

  public enum Block: Equatable, Sendable {
    /// The sender's name, before their part of a selection spanning messages.
    case sender(String)
    case paragraph(Text)
    case heading(level: Int, Text)
    /// `marker` is nil when the selection starts inside the item, after its marker.
    case listItem(depth: Int, marker: ListMarker?, Text)
    case code(language: String?, String)
    case quote(Text)
    case table(rows: [[Text]], hasHeader: Bool)
  }

  /// What a rendered text view shows, for the selection projection.
  public enum SurfaceRole: Equatable, Sendable {
    case body
    case heading(level: Int)
    case listItem(depth: Int)
    case code(language: String?)
    case quote
    case tableCell(table: Int, row: Int, column: Int, isHeader: Bool)
  }

  /// What a rendered literal (content without a text view) is.
  public enum LiteralRole: Equatable, Sendable {
    case listMarker(ListMarker)
    case block
  }

  public var blocks: [Block]

  public init(blocks: [Block]) {
    self.blocks = blocks
  }

  public var isEmpty: Bool { blocks.isEmpty }

  // MARK: Building

  /// Blocks for one message's selected parts, in document order.
  @MainActor
  public static func blocks(
    parts: [RichTextMultiSurfaceSelection.DocumentPart],
    surfaceTexts: [NSAttributedString],
    roles: [SurfaceRole],
    literals: [NSAttributedString],
    literalRoles: [LiteralRole]
  ) -> [Block] {
    var blocks: [Block] = []
    var pendingMarker: ListMarker?
    var table: (id: Int, firstRow: Int, rows: [Int: [Int: Text]], header: Set<Int>)?

    func flushTable() {
      guard let current = table else { return }
      table = nil
      let rowKeys = current.rows.keys.sorted()
      let rows = rowKeys.map { key -> [Text] in
        let cells = current.rows[key] ?? [:]
        let width = (cells.keys.max() ?? -1) + 1
        return (0 ..< width).map { cells[$0] ?? Text(string: "") }
      }
      guard !rows.isEmpty else { return }
      let hasHeader = current.firstRow == rowKeys.first && current.header.contains(current.firstRow)
      blocks.append(.table(rows: rows, hasHeader: hasHeader))
    }

    for part in parts {
      switch part {
      case .separator:
        continue
      case let .literal(index):
        guard literals.indices.contains(index) else { continue }
        switch literalRoles.indices.contains(index) ? literalRoles[index] : .block {
        case let .listMarker(marker):
          pendingMarker = marker
        case .block:
          flushTable()
          let text = Text(string: literals[index].string)
          if !text.isBlank { blocks.append(.paragraph(text)) }
        }
      case let .surface(index, range):
        guard surfaceTexts.indices.contains(index), range.length > 0,
              NSMaxRange(range) <= surfaceTexts[index].length
        else { continue }
        let rendered = surfaceTexts[index].attributedSubstring(from: range)
        let role = roles.indices.contains(index) ? roles[index] : .body
        if case let .tableCell(id, row, column, isHeader) = role {
          if table?.id != id {
            flushTable()
            table = (id, row, [:], [])
          }
          table?.rows[row, default: [:]][column] = Text(rendered: rendered)
          if isHeader { table?.header.insert(row) }
          continue
        }
        flushTable()
        switch role {
        case .body, .tableCell:
          blocks.append(.paragraph(Text(rendered: rendered)))
        case let .heading(level):
          blocks.append(.heading(level: level, Text(rendered: rendered)))
        case let .listItem(depth):
          blocks.append(.listItem(depth: depth, marker: pendingMarker, Text(rendered: rendered)))
        case let .code(language):
          blocks.append(.code(language: language, rendered.string))
        case .quote:
          blocks.append(.quote(Text(rendered: rendered)))
        }
        pendingMarker = nil
      }
    }
    flushTable()
    return blocks
  }

  // MARK: Plain text and Markdown

  /// Plain text as it reads on screen: list markers, tab-separated table cells, no syntax.
  public var plainText: String { portable.text }

  /// Plain text with inline formatting as entities, for native rich text (RTF).
  public var portable: (text: String, entities: MessageEntities) {
    render(markdown: false)
  }

  /// Markdown structure (headings, list markers, code fences, tables) as text, with inline
  /// formatting and quotes still as entities. Composers load it as editable Markdown with live
  /// mentions; `markdown` serializes the entities too.
  public var markdownSource: (text: String, entities: MessageEntities) {
    render(markdown: true)
  }

  public var markdown: String {
    let source = markdownSource
    return MessageMarkdown.string(text: source.text, entities: source.entities)
  }

  private struct Writer {
    var text = ""
    var length = 0
    var entities: [MessageEntity] = []

    mutating func append(_ string: String) {
      text += string
      length += string.utf16.count
    }

    mutating func append(_ value: Text, adding extra: MessageEntity.TypeEnum? = nil) {
      for entity in value.entities {
        var shifted = entity
        shifted.offset += Int64(length)
        entities.append(shifted)
      }
      if let extra, !value.string.isEmpty {
        entities.append(MessageEntity.with {
          $0.type = extra
          $0.offset = Int64(length)
          $0.length = Int64(value.string.utf16.count)
        })
      }
      append(value.string)
    }
  }

  private func render(markdown: Bool) -> (text: String, entities: MessageEntities) {
    var writer = Writer()
    var previous: Block?
    for block in blocks {
      if let previous { writer.append(Self.separator(between: previous, and: block)) }
      previous = block
      switch block {
      case let .sender(name):
        writer.append(Text(string: "\(name):"), adding: .bold)
      case let .paragraph(text):
        writer.append(text)
      case let .heading(level, text):
        if markdown {
          writer.append(String(repeating: "#", count: min(max(level, 1), 6)) + " ")
          writer.append(text)
        } else {
          writer.append(text, adding: .bold)
        }
      case let .listItem(depth, marker, text):
        let indent = String(repeating: "    ", count: max(depth - 1, 0))
        writer.append(indent)
        switch marker {
        case .bullet?: writer.append(markdown ? "- " : "• ")
        case let .ordered(number)?: writer.append("\(number). ")
        case nil: break
        }
        writer.append(text)
      case let .code(language, code):
        if markdown {
          let fence = String(repeating: "`", count: max(3, Self.longestBacktickRun(in: code) + 1))
          writer.append("\(fence)\(language ?? "")\n\(code)\n\(fence)")
        } else {
          writer.append(Text(string: code), adding: .pre)
        }
      case let .quote(text):
        writer.append(text, adding: .blockquote)
      case let .table(rows, _):
        if markdown {
          let width = rows.map(\.count).max() ?? 0
          for (index, row) in rows.enumerated() {
            if index > 0 { writer.append("\n") }
            writer.append("|")
            for column in 0 ..< width {
              writer.append(" ")
              let cell = column < row.count ? row[column] : Text(string: "")
              if cell.string.contains("|") || cell.string.contains("\n") {
                writer.append(cell.string.replacingOccurrences(of: "|", with: "\\|")
                  .replacingOccurrences(of: "\n", with: " "))
              } else {
                writer.append(cell)
              }
              writer.append(" |")
            }
            // Markdown tables need a header row; the first row serves when none was selected.
            if index == 0 {
              writer.append("\n|" + String(repeating: " --- |", count: width))
            }
          }
        } else {
          for (index, row) in rows.enumerated() {
            if index > 0 { writer.append("\n") }
            for (column, cell) in row.enumerated() {
              if column > 0 { writer.append("\t") }
              writer.append(cell)
            }
          }
        }
      }
    }
    return (writer.text, MessageEntities.with { $0.entities = writer.entities })
  }

  /// List items stay on consecutive lines and a sender's name sits right above their text;
  /// every other block boundary is a blank line, like the source Markdown.
  private static func separator(between previous: Block, and next: Block) -> String {
    switch (previous, next) {
    case (.sender, _): "\n"
    case (.listItem, .listItem): "\n"
    default: "\n\n"
    }
  }

  private static func longestBacktickRun(in text: String) -> Int {
    var longest = 0
    var current = 0
    for character in text {
      current = character == "`" ? current + 1 : 0
      longest = max(longest, current)
    }
    return longest
  }

  // MARK: HTML

  /// Semantic HTML (headings, nested lists, tables, code, quotes, links) for rich editors
  /// such as Notion, Notes and Google Docs.
  public var html: String {
    var body = ""
    var openLists: [(depth: Int, ordered: Bool)] = []

    func closeLists(above depth: Int) {
      while let last = openLists.last, last.depth > depth {
        body += last.ordered ? "</li></ol>" : "</li></ul>"
        openLists.removeLast()
      }
    }

    for block in blocks {
      if case let .listItem(depth, marker, text) = block {
        let ordered = if case .ordered = marker { true } else { false }
        closeLists(above: depth)
        if let last = openLists.last, last.depth == depth {
          if last.ordered == ordered {
            body += "</li>"
          } else {
            body += last.ordered ? "</li></ol>" : "</li></ul>"
            openLists.removeLast()
          }
        }
        while (openLists.last?.depth ?? 0) < depth {
          let level = (openLists.last?.depth ?? 0) + 1
          var start = ""
          if level == depth, case let .ordered(number)? = marker, number != 1 { start = " start=\"\(number)\"" }
          body += ordered && level == depth ? "<ol\(start)>" : "<ul>"
          openLists.append((level, ordered && level == depth))
          if level < depth { body += "<li>" }
        }
        body += "<li>" + Self.inlineHTML(text)
        continue
      }
      closeLists(above: 0)
      switch block {
      case let .sender(name):
        body += "<p><strong>\(Self.escape(name)):</strong></p>"
      case let .paragraph(text):
        body += Self.paragraphHTML(text)
      case let .heading(level, text):
        let tag = "h\(min(max(level, 1), 6))"
        body += "<\(tag)>\(Self.inlineHTML(text))</\(tag)>"
      case let .code(language, code):
        let attribute = language.map { " class=\"language-\(Self.escape($0))\"" } ?? ""
        body += "<pre><code\(attribute)>\(Self.escape(code))</code></pre>"
      case let .quote(text):
        body += "<blockquote><p>\(Self.inlineHTML(text))</p></blockquote>"
      case let .table(rows, hasHeader):
        body += "<table>"
        for (index, row) in rows.enumerated() {
          let header = hasHeader && index == 0
          if index == 0, header { body += "<thead>" }
          if index == (hasHeader ? 1 : 0) { body += "<tbody>" }
          body += "<tr>"
          for cell in row {
            body += header ? "<th>\(Self.inlineHTML(cell))</th>" : "<td>\(Self.inlineHTML(cell))</td>"
          }
          body += "</tr>"
          if index == 0, header { body += "</thead>" }
        }
        if !(hasHeader && rows.count == 1) { body += "</tbody>" }
        body += "</table>"
      case .listItem:
        break
      }
    }
    closeLists(above: 0)
    return "<html><head><meta charset=\"utf-8\"></head><body>\(body)</body></html>"
  }

  /// A paragraph from a plain message may hold code blocks; those become `<pre>` blocks.
  private static func paragraphHTML(_ text: Text) -> String {
    let source = text.string as NSString
    let blocks = text.entities
      .filter { $0.type == .pre }
      .map { NSRange(location: Int($0.offset), length: Int($0.length)) }
      .filter { $0.location >= 0 && NSMaxRange($0) <= source.length }
      .sorted { $0.location < $1.location }
    var html = ""
    var cursor = 0
    func paragraph(upTo end: Int) {
      guard end > cursor else { return }
      let range = NSRange(location: cursor, length: end - cursor)
      let part = slice(text, range)
      if !part.isBlank { html += "<p>\(inlineHTML(part))</p>" }
    }
    for block in blocks where block.location >= cursor {
      paragraph(upTo: block.location)
      html += "<pre><code>\(escape(source.substring(with: block)))</code></pre>"
      cursor = NSMaxRange(block)
    }
    paragraph(upTo: source.length)
    return html
  }

  /// The part of `text` in `range`, without the line breaks around it.
  private static func slice(_ text: Text, _ range: NSRange) -> Text {
    let source = text.string as NSString
    var start = range.location
    var end = NSMaxRange(range)
    func isBreak(_ unit: unichar) -> Bool { unit == 10 || unit == 13 }
    while start < end, isBreak(source.character(at: start)) { start += 1 }
    while end > start, isBreak(source.character(at: end - 1)) { end -= 1 }
    let entities = text.entities.compactMap { entity -> MessageEntity? in
      let lower = max(Int(entity.offset), start)
      let upper = min(Int(entity.offset + entity.length), end)
      guard upper > lower else { return nil }
      var clipped = entity
      clipped.offset = Int64(lower - start)
      clipped.length = Int64(upper - lower)
      return clipped
    }
    return Text(string: source.substring(with: NSRange(location: start, length: end - start)), entities: entities)
  }

  /// Inline formatting as nested tags. Each run between entity edges reopens its tags, so
  /// overlapping entities still produce well-formed HTML.
  private static func inlineHTML(_ text: Text) -> String {
    let source = text.string as NSString
    let length = source.length
    let entities = text.entities.filter {
      $0.offset >= 0 && $0.length > 0 && Int($0.offset + $0.length) <= length && tagOrder($0.type) != nil
    }
    var edges = Set([0, length])
    for entity in entities {
      edges.insert(Int(entity.offset))
      edges.insert(Int(entity.offset + entity.length))
    }
    let points = edges.sorted()
    var html = ""
    for (start, end) in zip(points, points.dropFirst()) where end > start {
      let active = entities
        .filter { Int($0.offset) <= start && Int($0.offset + $0.length) >= end }
        .sorted { (tagOrder($0.type) ?? 0) < (tagOrder($1.type) ?? 0) }
      let content = escape(source.substring(with: NSRange(location: start, length: end - start)))
        .replacingOccurrences(of: "\n", with: "<br>")
      var open = ""
      var close = ""
      for entity in active {
        let (opening, closing) = tags(for: entity, text: source)
        open += opening
        close = closing + close
      }
      html += open + content + close
    }
    return html
  }

  private static func tagOrder(_ type: MessageEntity.TypeEnum) -> Int? {
    switch type {
    case .textURL, .url: 0
    case .bold: 1
    case .italic: 2
    case .underline: 3
    case .strikethrough: 4
    case .highlight: 5
    case .code, .pre: 6
    default: nil
    }
  }

  private static func tags(for entity: MessageEntity, text: NSString) -> (String, String) {
    switch entity.type {
    case .textURL:
      return ("<a href=\"\(escape(entity.textURL.url))\">", "</a>")
    case .url:
      let target = text.substring(with: NSRange(location: Int(entity.offset), length: Int(entity.length)))
      let href = target.contains("://") ? target : "https://\(target)"
      return ("<a href=\"\(escape(href))\">", "</a>")
    case .bold: return ("<strong>", "</strong>")
    case .italic: return ("<em>", "</em>")
    case .underline: return ("<u>", "</u>")
    case .strikethrough: return ("<s>", "</s>")
    case .highlight: return ("<mark>", "</mark>")
    default: return ("<code>", "</code>")
    }
  }

  private static func escape(_ string: String) -> String {
    string
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
  }
}
