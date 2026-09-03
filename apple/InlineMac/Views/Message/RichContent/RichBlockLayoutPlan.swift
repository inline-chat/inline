import AppKit
import InlineKit
import InlineProtocol
import TextProcessing

enum RichBlockActivityKind: String, Codable, Hashable {
  case reasoning, explore, read, search, edit, delete, move, command, web, tool

  init?(_ value: InlineProtocol.BlockDisclosure.ActivityKind) {
    switch value {
    case .reasoning: self = .reasoning
    case .explore: self = .explore
    case .read: self = .read
    case .search: self = .search
    case .edit: self = .edit
    case .delete: self = .delete
    case .move: self = .move
    case .command: self = .command
    case .web: self = .web
    case .tool: self = .tool
    case .unspecified, .UNRECOGNIZED: return nil
    }
  }

  var symbolName: String {
    switch self {
    case .reasoning: "brain"
    case .explore, .search: "magnifyingglass"
    case .read: "doc.text"
    case .edit: "square.and.pencil"
    case .delete: "trash"
    case .move: "folder"
    case .command: "terminal"
    case .web: "globe"
    case .tool: "wrench.and.screwdriver"
    }
  }
}

enum RichBlockTextRole: Codable, Hashable {
  case paragraph
  case heading(level: Int)
  case footer
  case disclosureSummary(progress: Bool, expanded: Bool, activity: RichBlockActivityKind?)
  case listMarker
}

enum RichBlockRenderKind: String, Codable, Hashable {
  case math
  case text
  case listMarker
  case code
  case disclosure
  case separator
  case image
  case album
  case quote
  case table
}

struct RichBlockLayoutPlan: Codable, Hashable {
  struct TrailingTextLine: Codable, Hashable {
    var usedWidth: CGFloat
    var height: CGFloat
    var isRTL: Bool
  }

  struct TextNode: Codable, Hashable {
    var rangeOffset: Int
    var rangeLength: Int
    var role: RichBlockTextRole
    var literal: String?
    var isRTL: Bool
  }

  struct CodeNode: Codable, Hashable {
    var rangeOffset: Int
    var rangeLength: Int
    var language: String?
    var gutterWidth: CGFloat
    var lineCount: Int
  }

  struct MathNode: Codable, Hashable {
    var range: NSRange
    var imageSize: CGSize?
  }

  struct ImageNode: Codable, Hashable {
    enum State: Codable, Hashable {
      case pending
      case ready(PhotoInfo)
      case unavailable
    }

    var path: BlockContentPath
    var frame: CGRect
    var state: State
  }

  struct AlbumNode: Codable, Hashable {
    var items: [ImageNode]
  }

  struct QuoteNode: Codable, Hashable {
    var isRTL: Bool
  }

  enum TableAlignment: String, Codable, Hashable {
    case left
    case center
    case right
  }

  struct TableNode: Codable, Hashable {
    struct Cell: Codable, Hashable {
      var rangeOffset: Int
      var rangeLength: Int
      var frame: CGRect
      var alignment: TableAlignment
      var isHeader: Bool
    }

    var cells: [Cell]
    var contentWidth: CGFloat
    var isRTL: Bool
  }

  enum NodeKind: Codable, Hashable {
    case math(MathNode)
    case text(TextNode)
    case code(CodeNode)
    case separator
    case image(ImageNode)
    case album(AlbumNode)
    case quote(QuoteNode)
    case table(TableNode)
  }

  struct Node: Codable, Hashable {
    var path: BlockContentPath
    var frame: CGRect
    var kind: NodeKind

    var reuseKind: RichBlockRenderKind {
      switch kind {
      case .math: return .math
      case let .text(text):
        if case .disclosureSummary = text.role { return .disclosure }
        if case .listMarker = text.role { return .listMarker }
        return .text
      case .code:
        return .code
      case .separator:
        return .separator
      case .image:
        return .image
      case .album:
        return .album
      case .quote:
        return .quote
      case .table:
        return .table
      }
    }
  }

  var size: CGSize
  var mathSignature: Int
  /// Pixels/readiness used to measure this plan travel with the live handoff.
  /// Geometry caches and diagnostic JSON deliberately do not retain them.
  var mathSnapshot: RichTextMath.Snapshot? = nil
  var contentHorizontalInset: CGFloat
  var nodes: [Node]
  var trailingTextLine: TrailingTextLine?

  private enum CodingKeys: String, CodingKey {
    case size, mathSignature, contentHorizontalInset, nodes, trailingTextLine
  }

  // Snapshot ownership does not change geometric equality. Its render inputs
  // and availability are already represented by mathSignature.
  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.size == rhs.size && lhs.mathSignature == rhs.mathSignature
      && lhs.contentHorizontalInset == rhs.contentHorizontalInset
      && lhs.nodes == rhs.nodes && lhs.trailingTextLine == rhs.trailingTextLine
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(size); hasher.combine(mathSignature); hasher.combine(contentHorizontalInset)
    hasher.combine(nodes); hasher.combine(trailingTextLine)
  }
}
