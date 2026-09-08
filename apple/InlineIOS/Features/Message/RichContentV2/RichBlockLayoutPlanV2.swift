import InlineKit
import InlineProtocol
import TextProcessing
import UIKit

enum RichBlockActivityKindV2: Hashable {
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

enum RichBlockTextRoleV2: Hashable {
  case paragraph
  case heading(level: Int)
  case footer
  case disclosure(progress: Bool, expanded: Bool, activity: RichBlockActivityKindV2? = nil)
  case listMarker
}

enum RichBlockRenderKindV2: Hashable {
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

struct RichBlockLayoutPlanV2: Hashable {
  struct TrailingTextLine: Hashable {
    let usedWidth: CGFloat
    let height: CGFloat
    let isRTL: Bool
  }

  struct TextNode: Hashable {
    let range: NSRange
    let role: RichBlockTextRoleV2
    let literal: String?
    let isRTL: Bool
  }

  struct CodeNode: Hashable {
    let range: NSRange
    let language: String?
    let gutterWidth: CGFloat
    let lineCount: Int
    let contentWidth: CGFloat
  }

  struct MathNode: Hashable {
    let range: NSRange
    let imageSize: CGSize?
  }

  struct ImageNode: Hashable {
    enum State: Hashable {
      case pending
      case ready(PhotoInfo)
      case unavailable
    }

    let path: BlockContentPath
    let frame: CGRect
    let alt: String?
    let state: State
  }

  struct AlbumNode: Hashable {
    let items: [ImageNode]
    let contentWidth: CGFloat
  }

  struct QuoteNode: Hashable {
    let isRTL: Bool
  }

  enum TableAlignment: Hashable {
    case leading
    case center
    case trailing
  }

  struct TableNode: Hashable {
    struct Cell: Hashable {
      let range: NSRange
      let frame: CGRect
      let alignment: TableAlignment
      let isHeader: Bool
    }

    let cells: [Cell]
    let contentWidth: CGFloat
    let isRTL: Bool
  }

  enum NodeKind: Hashable {
    case math(MathNode)
    case text(TextNode)
    case code(CodeNode)
    case separator
    case image(ImageNode)
    case album(AlbumNode)
    case quote(QuoteNode)
    case table(TableNode)
  }

  struct Node: Hashable {
    let path: BlockContentPath
    var frame: CGRect
    let kind: NodeKind

    var reuseKind: RichBlockRenderKindV2 {
      switch kind {
        case .math: .math
        case let .text(text):
          switch text.role {
            case .listMarker: .listMarker
            case .disclosure: .disclosure
            default: .text
          }
        case .code: .code
        case .separator: .separator
        case .image: .image
        case .album: .album
        case .quote: .quote
        case .table: .table
      }
    }
  }

  let size: CGSize
  let mathSignature: Int
  /// Keep measured readiness until view binding, outside the geometry cache.
  var mathSnapshot: RichTextMath.Snapshot? = nil
  let nodes: [Node]
  let trailingTextLine: TrailingTextLine?

  // Snapshot ownership is separate from the geometry's mathSignature.
  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.size == rhs.size && lhs.mathSignature == rhs.mathSignature
      && lhs.nodes == rhs.nodes && lhs.trailingTextLine == rhs.trailingTextLine
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(size); hasher.combine(mathSignature)
    hasher.combine(nodes); hasher.combine(trailingTextLine)
  }
}
