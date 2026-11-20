import InlineMessageLayout
import TextProcessing
import UIKit

/// A message's text as the context menu selects it: where each block sits in the preview, and
/// what copy needs between them (list markers, table structure, block breaks). Rich bodies
/// project the same way as macOS's `RichBlockContentView.selectionProjection`, so a selection
/// copies alike on both.
struct MessageSelectableText {
  typealias Role = MessageClipboardDocument.SurfaceRole

  /// Geometry in the preview's coordinates, one surface per block of text.
  let surfaces: TextSelectionSurfaces
  /// Surfaces and literals in reading order, with what goes between them.
  let document: [RichTextMultiSurfaceSelection.DocumentItem]
  let roles: [Role]
  /// Text shown without a surface of its own: list markers.
  let literals: [NSAttributedString]
  let literalRoles: [MessageClipboardDocument.LiteralRole]

  var length: Int { surfaces.length }

  /// A plain body: one block of text whose origin is at `origin`.
  static func plain(_ layout: TextLayout, origin: CGPoint) -> MessageSelectableText {
    MessageSelectableText(
      surfaces: TextSelectionSurfaces(layout: layout, origin: origin),
      document: [.init(content: .surface(0), separatorAfter: "")],
      roles: [.body],
      literals: [],
      literalRoles: []
    )
  }

  /// A rich body whose content origin is at `origin`. Paragraphs, headings, list items, quotes,
  /// code, table cells and agent cards' text are selectable; markers copy with their item.
  /// `scrollOffsets` are the code blocks' and tables' sideways offsets by path. Nil when no
  /// text shows.
  ///
  /// `wholeMessage` also takes what shows but doesn't select, for copying the whole message:
  /// disclosure summaries, written out in full, and diffs.
  static func rich(
    _ rich: RichLayout,
    origin: CGPoint,
    scrollOffsets: [RichPath: CGFloat],
    wholeMessage: Bool = false
  ) -> MessageSelectableText? {
    var builder = Builder()
    let nodes = rich.nodes
    let quotePaths = nodes.compactMap { placed -> RichPath? in
      if case .quote = placed.node { return placed.path }
      return nil
    }
    // A marker's path is its item's with -1 appended.
    let itemPaths = nodes.compactMap { placed -> RichPath? in
      if case .marker = placed.node { return RichPath(Array(placed.path.components.dropLast())) }
      return nil
    }

    func role(of path: RichPath, textRole: RichTextRole) -> Role {
      let depth = itemPaths.count(where: { path.isStrictDescendant(of: $0) })
      if depth > 0 { return .listItem(depth: depth) }
      if case let .heading(level) = textRole { return .heading(level: level) }
      if quotePaths.contains(where: { path.isStrictDescendant(of: $0) }) { return .quote }
      return .body
    }

    for (index, placed) in nodes.enumerated() {
      let frame = placed.frame.offsetBy(dx: origin.x, dy: origin.y)
      switch placed.node {
      case let .text(layout, textRole):
        builder.surface(layout, at: frame.origin, role: role(of: placed.path, textRole: textRole), separatorAfter: "\n")
      case let .marker(layout, _):
        // The marker leads the item's first text, so a selection starting there copies it.
        let item = RichPath(Array(placed.path.components.dropLast()))
        let leads = nodes[(index + 1)...]
          .prefix { $0.path.isStrictDescendant(of: item) }
          .contains { Self.hasText($0.node) }
        builder.marker(layout.text.string, leadsNextSurface: leads)
      case let .code(code):
        let offset = scrollOffsets[placed.path] ?? 0
        let visible = CGRect(
          x: frame.minX,
          y: frame.minY + code.textOrigin.y,
          width: frame.width,
          height: max(0, frame.height - code.textOrigin.y)
        )
        builder.surface(
          code.text,
          at: CGPoint(x: frame.minX + code.textOrigin.x - offset, y: frame.minY + code.textOrigin.y),
          visibleRect: visible,
          role: .code(language: code.language),
          separatorAfter: "\n"
        )
      case let .table(table):
        // Right-to-left tables open at their trailing edge, where the first column is.
        let offset = scrollOffsets[placed.path]
          ?? (table.isRightToLeft ? max(0, table.contentSize.width - frame.width) : 0)
        for (cellIndex, cell) in table.cells.enumerated() {
          let sameRow = cellIndex + 1 < table.cells.count && table.cells[cellIndex + 1].row == cell.row
          builder.surface(
            cell.text,
            at: CGPoint(x: frame.minX + cell.textFrame.minX - offset, y: frame.minY + cell.textFrame.minY),
            visibleRect: frame,
            role: .tableCell(table: index, row: cell.row, column: cell.column, isHeader: cell.isHeader),
            separatorAfter: sameRow ? "\t" : "\n"
          )
        }
      case let .card(card):
        for part in card.parts {
          guard case let .text(layout) = part.kind else { continue }
          builder.surface(
            layout,
            at: CGPoint(x: frame.minX + part.frame.minX, y: frame.minY + part.frame.minY),
            role: .body,
            separatorAfter: "\n"
          )
        }
      case let .disclosure(disclosure) where wholeMessage:
        // A closed row shows only its summary; an open one's children follow as their own nodes.
        builder.block(disclosure.fullSummary.attributedString)
      case let .diff(diff) where wholeMessage:
        builder.block(diff.path.attributedString)
        if let body = diff.body {
          builder.surface(body, at: frame.origin, role: .code(language: "diff"), separatorAfter: "\n")
        }
      case .quote, .separator, .image, .album, .disclosure, .diff:
        // Disclosure summaries are cut to one line and diffs scroll in two directions; neither
        // selects yet.
        continue
      }
    }
    guard !builder.surfaces.isEmpty else { return nil }
    return MessageSelectableText(
      surfaces: TextSelectionSurfaces(builder.surfaces),
      document: builder.document,
      roles: builder.roles,
      literals: builder.literals,
      literalRoles: builder.literalRoles
    )
  }

  /// Whether a node draws text the projection makes a surface of.
  private static func hasText(_ node: RichLayout.Node) -> Bool {
    switch node {
    case let .text(layout, _): layout.length > 0
    case let .code(code): code.text.length > 0
    case let .table(table): table.cells.contains { $0.text.length > 0 }
    case let .card(card): card.parts.contains { if case let .text(layout) = $0.kind { layout.length > 0 } else { false } }
    default: false
    }
  }

  // MARK: - Copy

  /// The selected text as copy blocks: headings, list items with their markers, code, tables.
  @MainActor
  func clipboardDocument(for range: NSRange) -> MessageClipboardDocument {
    let isWhole = range.location == 0 && range.length >= length
    guard let parts = RichTextMultiSurfaceSelection.documentParts(
      document: document,
      surfaceRanges: surfaces.surfaceRanges(for: range),
      includeDocumentEdges: isWhole
    ) else { return MessageClipboardDocument(blocks: []) }
    let blocks = MessageClipboardDocument.blocks(
      parts: parts,
      surfaceTexts: surfaces.surfaces.map(\.layout.text.attributedString),
      roles: roles,
      literals: literals,
      literalRoles: literalRoles
    )
    return MessageClipboardDocument(blocks: blocks.filter {
      if case let .paragraph(text) = $0 { return !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      return true
    })
  }

  // MARK: - Builder

  private struct Builder {
    var surfaces: [TextSelectionSurfaces.Surface] = []
    var roles: [Role] = []
    var document: [RichTextMultiSurfaceSelection.DocumentItem] = []
    var literals: [NSAttributedString] = []
    var literalRoles: [MessageClipboardDocument.LiteralRole] = []

    mutating func surface(
      _ layout: TextLayout,
      at origin: CGPoint,
      visibleRect: CGRect? = nil,
      role: Role,
      separatorAfter: String
    ) {
      // Empty text holds no caret; it would only add a stray separator.
      guard layout.length > 0, !layout.lines.isEmpty else { return }
      document.append(.init(content: .surface(surfaces.count), separatorAfter: separatorAfter))
      surfaces.append(.init(layout: layout, origin: origin, visibleRect: visibleRect))
      roles.append(role)
    }

    /// Nothing that makes a surface comes between a marker and its item's first text, so
    /// that text becomes the next surface.
    mutating func marker(_ text: String, leadsNextSurface: Bool) {
      guard !text.isEmpty else { return }
      document.append(.init(
        content: .literal(literals.count, leadingForSurface: leadsNextSurface ? surfaces.count : nil),
        separatorAfter: " "
      ))
      literals.append(NSAttributedString(string: text))
      literalRoles.append(.listMarker(.init(rendered: text)))
    }

    /// Text that copies as a paragraph of its own but has no surface.
    mutating func block(_ text: NSAttributedString) {
      guard !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
      document.append(.init(content: .literal(literals.count, leadingForSurface: nil), separatorAfter: "\n"))
      literals.append(text)
      literalRoles.append(.block)
    }
  }
}

private extension RichPath {
  func isStrictDescendant(of ancestor: RichPath) -> Bool {
    components.count > ancestor.components.count && components.starts(with: ancestor.components)
  }
}
