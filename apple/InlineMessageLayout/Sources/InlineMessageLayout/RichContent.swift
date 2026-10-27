import CoreGraphics

/// A rich message as a tree of blocks. Text arrives styled by the host (fonts, colors, links);
/// the planner only measures and places it.
public indirect enum RichBlock: Hashable, Sendable {
  case text(MessageText, role: RichTextRole)
  case list(RichList)
  case quote(children: [RichBlock], isRightToLeft: Bool)
  case code(RichCode)
  case table(RichTable)
  case separator
  case image(RichImage)
  case album([RichImage])
  case disclosure(RichDisclosure)
}

public enum RichTextRole: Hashable, Sendable {
  case paragraph
  case heading(level: Int)
  case footer
}

public struct RichList: Hashable, Sendable {
  public struct Item: Hashable, Sendable {
    /// "•", "3." or a checkbox, styled like the body text.
    public var marker: MessageText
    public var children: [RichBlock]

    public init(marker: MessageText, children: [RichBlock]) {
      self.marker = marker
      self.children = children
    }
  }

  public var items: [Item]
  public var isRightToLeft: Bool

  public init(items: [Item], isRightToLeft: Bool = false) {
    self.items = items
    self.isRightToLeft = isRightToLeft
  }
}

/// Code never wraps; its box spans the content width and scrolls sideways.
public struct RichCode: Hashable, Sendable {
  public var text: MessageText
  /// "1\n2\n…" for the gutter, or nil for no line numbers.
  public var lineNumbers: MessageText?
  /// The language name for the header, or nil for no header.
  public var languageLabel: MessageText?
  /// The language identifier as written, for the host's syntax colors.
  public var language: String?

  public init(text: MessageText, lineNumbers: MessageText? = nil, languageLabel: MessageText? = nil, language: String? = nil) {
    self.text = text
    self.lineNumbers = lineNumbers
    self.languageLabel = languageLabel
    self.language = language
  }
}

public struct RichTable: Hashable, Sendable {
  public enum Alignment: Hashable, Sendable {
    case leading
    case center
    case trailing
  }

  /// The first row is the header. Every row has the same number of cells.
  public var rows: [[MessageText]]
  /// Per column; missing columns use `leading`.
  public var alignments: [Alignment]
  public var isRightToLeft: Bool

  public init(rows: [[MessageText]], alignments: [Alignment] = [], isRightToLeft: Bool = false) {
    self.rows = rows
    self.alignments = alignments
    self.isRightToLeft = isRightToLeft
  }
}

public struct RichImage: Hashable, Sendable {
  public var id: String
  /// Pixel size when known; images without one reserve a 240×180 slot.
  public var size: CGSize?

  public init(id: String, size: CGSize?) {
    self.id = id
    self.size = size
  }
}

public struct RichDisclosure: Hashable, Sendable {
  public var summary: MessageText
  public var children: [RichBlock]
  public var isExpanded: Bool
  public var isInProgress: Bool
  public var hasActivityIcon: Bool
  public var isRightToLeft: Bool

  public init(
    summary: MessageText,
    children: [RichBlock],
    isExpanded: Bool,
    isInProgress: Bool = false,
    hasActivityIcon: Bool = false,
    isRightToLeft: Bool = false
  ) {
    self.summary = summary
    self.children = children
    self.isExpanded = isExpanded
    self.isInProgress = isInProgress
    self.hasActivityIcon = hasActivityIcon
    self.isRightToLeft = isRightToLeft
  }
}

/// Identity of a block in the tree: block indexes, with list items and table cells adding
/// their own index. Stable across updates, so nodes animate between layouts.
public struct RichPath: Hashable, Sendable, CustomStringConvertible {
  public var components: [Int]

  public init(_ components: [Int] = []) {
    self.components = components
  }

  public func appending(_ index: Int) -> RichPath {
    RichPath(components + [index])
  }

  public var description: String { components.map(String.init).joined(separator: ".") }
}

/// Spacing and sizes for rich content, phone-sized versions of the macOS renderer's.
public struct RichLayoutMetrics: Hashable, Sendable {
  public var blockSpacing: CGFloat = 8
  /// Extra space above a heading that follows other blocks.
  public var majorHeadingSpacing: CGFloat = 7
  public var minorHeadingSpacing: CGFloat = 5
  public var listItemSpacing: CGFloat = 4
  public var listLeadingInset: CGFloat = 3
  public var nestedListIndent: CGFloat = 3
  public var listMarkerGap: CGFloat = 6
  public var unorderedMarkerWidth: CGFloat = 16
  public var quoteLeadingInset: CGFloat = 9
  public var quoteTrailingInset: CGFloat = 9
  public var quoteVerticalInset: CGFloat = 6
  public var codeHeaderHeight: CGFloat = 21
  public var codeHorizontalInset: CGFloat = 8
  public var codeHeaderBodyTopInset: CGFloat = 3
  public var codeBodyTopInset: CGFloat = 8
  public var codeBodyBottomInset: CGFloat = 9
  public var codeGutterTrailingInset: CGFloat = 4
  public var codeGutterGap: CGFloat = 12
  public var tableHorizontalPadding: CGFloat = 10
  public var tableVerticalPadding: CGFloat = 7
  public var tableMinimumRowHeight: CGFloat = 32
  public var separatorMargin: CGFloat = 4
  public var maximumImageSide: CGFloat = 420
  public var albumHeight: CGFloat = 126
  public var albumItemSpacing: CGFloat = 6
  public var disclosureChevronSide: CGFloat = 14
  public var disclosureChevronGap: CGFloat = 4
  public var disclosureActivitySide: CGFloat = 14
  public var disclosureActivityGap: CGFloat = 5
  /// Content past these limits falls back to plain text, as on the server.
  public var maximumDepth = 16
  public var maximumNodes = 2_048
  public var maximumTableCells = 256

  public init() {}
}

/// Rich content placed for one width. Frames are in the content's coordinates, y-down,
/// pixel-aligned.
public struct RichLayout: Sendable {
  public enum Node: Sendable {
    case text(TextLayout, role: RichTextRole)
    case marker(TextLayout)
    case code(Code)
    /// A quote's rail and fill, behind its children.
    case quote(isRightToLeft: Bool)
    case separator
    case table(Table)
    case image(id: String)
    case album([AlbumItem])
    case disclosure(Disclosure)
  }

  public struct Code: Sendable {
    public var text: TextLayout
    public var textOrigin: CGPoint
    public var lineNumbers: TextLayout?
    public var lineNumbersOrigin: CGPoint
    public var languageLabel: TextLayout?
    public var languageLabelOrigin: CGPoint
    public var language: String?
    /// Scrollable width of the body; wider than the box when lines are long.
    public var contentWidth: CGFloat
  }

  public struct Table: Sendable {
    public struct Cell: Sendable {
      public var row: Int
      public var column: Int
      /// In the table's scrollable content.
      public var frame: CGRect
      public var text: TextLayout
      /// The text's frame in the table's content.
      public var textFrame: CGRect
      public var isHeader: Bool
    }

    public var cells: [Cell]
    /// Scrollable size; wider than the box when columns don't fit.
    public var contentSize: CGSize
    public var isRightToLeft: Bool
  }

  public struct AlbumItem: Sendable {
    public var id: String
    /// In the album's scrollable content.
    public var frame: CGRect
  }

  public struct Disclosure: Sendable {
    public var summary: TextLayout
    /// In the node's coordinates.
    public var titleFrame: CGRect
    public var chevronFrame: CGRect
    public var activityFrame: CGRect?
    public var isExpanded: Bool
    public var isInProgress: Bool
  }

  public struct Placed: Sendable {
    public var path: RichPath
    public var frame: CGRect
    public var node: Node
  }

  /// The last line of a closing paragraph, where a message's time can sit inline.
  public struct TrailingLine: Hashable, Sendable {
    public var maxX: CGFloat
    public var baseline: CGFloat
    public var direction: TextDirection
  }

  public var size: CGSize
  public var nodes: [Placed]
  public var trailingLine: TrailingLine?
}
