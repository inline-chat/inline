import AppKit
import InlineProtocol

/// Geometry for the agent and bot blocks (bridge v2, spec §6): disclosure
/// status and meta, diff, fields, steps, callout, meter and form. Every text
/// part is a UTF-16 range into the message text, like the other blocks, and
/// every frame is relative to its node.
struct RichBlockTextRange: Codable, Hashable {
  var offset: Int
  var length: Int

  init(offset: Int, length: Int) {
    self.offset = offset
    self.length = length
  }

  init(_ text: InlineProtocol.BlockText) {
    offset = Int(text.offset)
    length = Int(text.length)
  }
}

enum RichBlockStatus: String, Codable, Hashable {
  case pending, running, waiting, done, failed, cancelled

  init?(_ status: InlineProtocol.BlockStatus) {
    switch status {
    case .pending: self = .pending
    case .running: self = .running
    case .waiting: self = .waiting
    case .done: self = .done
    case .failed: self = .failed
    case .cancelled: self = .cancelled
    case .unspecified, .UNRECOGNIZED: return nil
    }
  }

  var symbolName: String {
    switch self {
    case .pending: "circle.dotted"
    case .running: "circle.dashed"
    case .waiting: "hand.raised.fill"
    case .done: "checkmark.circle.fill"
    case .failed: "xmark.circle.fill"
    case .cancelled: "slash.circle"
    }
  }

  var accessibilityName: String {
    switch self {
    case .pending: String(localized: "Pending")
    case .running: String(localized: "Running")
    case .waiting: String(localized: "Waiting for you")
    case .done: String(localized: "Done")
    case .failed: String(localized: "Failed")
    case .cancelled: String(localized: "Cancelled")
    }
  }

  func tint(_ palette: RichBlockPalette) -> NSColor {
    switch self {
    case .pending, .cancelled: palette.tertiary
    case .running: palette.secondary
    case .waiting: .systemOrange
    case .done: .systemGreen
    case .failed: .systemRed
    }
  }
}

/// Trailing parts of a disclosure summary row.
struct RichBlockDisclosureDecoration: Codable, Hashable {
  var status: RichBlockStatus?
  var meta: RichBlockTextRange?
  var metaWidth: CGFloat
}

struct RichBlockFieldsNode: Codable, Hashable {
  struct Row: Codable, Hashable {
    var label: RichBlockTextRange
    var value: RichBlockTextRange
    var labelFrame: CGRect
    var valueFrame: CGRect
    var monospace: Bool
  }

  var rows: [Row]
  var isRTL: Bool
}

struct RichBlockStepsNode: Codable, Hashable {
  struct Step: Codable, Hashable {
    var text: RichBlockTextRange
    var detail: RichBlockTextRange?
    var status: RichBlockStatus?
    var markerFrame: CGRect
    var textFrame: CGRect
    var detailFrame: CGRect?
  }

  var steps: [Step]
  var isRTL: Bool
}

enum RichBlockCalloutTone: String, Codable, Hashable {
  case info, success, warning, error

  init(_ kind: InlineProtocol.BlockCallout.Kind) {
    switch kind {
    case .success: self = .success
    case .warning: self = .warning
    case .error: self = .error
    case .info, .unspecified, .UNRECOGNIZED: self = .info
    }
  }

  var symbolName: String {
    switch self {
    case .info: "info.circle.fill"
    case .success: "checkmark.circle.fill"
    case .warning: "exclamationmark.triangle.fill"
    case .error: "xmark.octagon.fill"
    }
  }

  var tint: NSColor {
    switch self {
    case .info: .systemBlue
    case .success: .systemGreen
    case .warning: .systemOrange
    case .error: .systemRed
    }
  }
}

/// The callout's own chrome (tint, icon, title). Its child blocks are
/// ordinary nodes laid out inside its frame.
struct RichBlockCalloutNode: Codable, Hashable {
  var tone: RichBlockCalloutTone
  var title: RichBlockTextRange?
  var titleFrame: CGRect?
  var iconFrame: CGRect
  var isRTL: Bool
}

enum RichBlockMeterTone: String, Codable, Hashable {
  case normal, warning, critical
}

struct RichBlockMeterNode: Codable, Hashable {
  var label: RichBlockTextRange
  var meta: RichBlockTextRange?
  var fraction: Double
  var tone: RichBlockMeterTone
  var labelFrame: CGRect
  var metaFrame: CGRect?
  var barFrame: CGRect
}

enum RichBlockDiffChange: String, Codable, Hashable {
  case added, modified, deleted, renamed

  init(_ change: InlineProtocol.BlockDiff.Change) {
    switch change {
    case .added: self = .added
    case .deleted: self = .deleted
    case .renamed: self = .renamed
    case .modified, .unspecified, .UNRECOGNIZED: self = .modified
    }
  }

  var symbolName: String {
    switch self {
    case .added: "plus.square"
    case .modified: "pencil.line"
    case .deleted: "minus.square"
    case .renamed: "arrow.right.square"
    }
  }
}

struct RichBlockDiffNode: Codable, Hashable {
  /// Diff bodies render at most this many lines; the sender's own
  /// `truncated` flag and the hidden remainder are both called out.
  static let maximumRenderedLines = 400

  var path: RichBlockTextRange
  var previousPath: RichBlockTextRange?
  var change: RichBlockDiffChange
  var additions: Int?
  var deletions: Int?
  var body: RichBlockTextRange?
  var renderedLineCount: Int
  var hiddenLineCount: Int
  var truncated: Bool
  var headerHeight: CGFloat
  var lineHeight: CGFloat
  var bodyContentWidth: CGFloat
}

struct RichBlockFormNode: Codable, Hashable {
  enum TextKind: String, Codable, Hashable { case singleLine, multiline, secret }

  struct Option: Codable, Hashable {
    var id: String
    var label: RichBlockTextRange
    var description: RichBlockTextRange?
    var frame: CGRect
  }

  enum Control: Codable, Hashable {
    /// Options listed as radio buttons or checkboxes.
    case choices(options: [Option], multiple: Bool, defaults: [String], otherFrame: CGRect?)
    /// Many single-choice options in a pop-up menu.
    case menu(options: [Option], defaults: [String], otherFrame: CGRect?)
    case text(kind: TextKind, placeholder: String?, defaultValue: String?, maxLength: Int?)
    case toggle(defaultValue: Bool)
    case number(defaultValue: Double?, minimum: Double?, maximum: Double?, step: Double?, integer: Bool)
  }

  struct Field: Codable, Hashable {
    var id: String
    var label: RichBlockTextRange
    var labelFrame: CGRect
    var description: RichBlockTextRange?
    var descriptionFrame: CGRect?
    var required: Bool
    var control: Control
    var controlFrame: CGRect
  }

  var formID: String
  var title: RichBlockTextRange?
  var titleFrame: CGRect?
  var fields: [Field]
  var submitLabel: String
  var submitFrame: CGRect
  var requiredGrant: Int
  var closed: Bool
  var isRTL: Bool
}
