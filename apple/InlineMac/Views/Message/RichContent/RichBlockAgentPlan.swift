import AppKit
import InlineKit
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
    // The Claude task list: a dashed circle waits, a spinner runs (drawn by the steps view).
    case .pending: "circle.dashed"
    case .running: "circle.dotted"
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
  /// A working row's live time, right after the summary: "Working 2m 12s".
  var elapsed: RichBlockElapsed? = nil
}

/// A progress row's live time. The plan only reserves its room; the row counts.
struct RichBlockElapsed: Codable, Hashable {
  /// Unix seconds the work started; nil counts from the message's time.
  var startedAt: Int64?
  /// The widest the time gets, so ticking never relays out the message.
  var reservedWidth: CGFloat
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
  /// A top-level plan draws as a rounded card, like the Claude task list.
  var isCard: Bool = false
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
    /// Monospaced, shown in the field's preview pane while this option is chosen.
    var preview: RichBlockTextRange? = nil
    /// Where the "Recommended" tag sits, in the option's coordinates; nil when not recommended.
    var tagFrame: CGRect? = nil
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
    /// A short topic above the question, such as "Auth method", drawn as a chip.
    var header: RichBlockTextRange? = nil
    /// The header's text; the chip pads around it.
    var headerFrame: CGRect? = nil
    /// The box under the choices that shows the chosen option's preview, sized for the
    /// tallest one so choosing never moves the message.
    var previewFrame: CGRect? = nil
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

// MARK: - Agent cards (plan proposal, approval, task suggestion, next step)

enum RichBlockAgentCardKind: String, Codable, Hashable {
  case planProposal, approval, taskSuggestion, nextStep
}

enum RichBlockDecisionState: String, Codable, Hashable {
  case pending, accepted, declined, expired, superseded

  init(_ state: InlineProtocol.BlockDecisionState) {
    switch state {
    case .accepted: self = .accepted
    case .declined: self = .declined
    case .expired: self = .expired
    case .superseded: self = .superseded
    case .pending, .unspecified, .UNRECOGNIZED: self = .pending
    }
  }
}

enum RichBlockChipTone: String, Codable, Hashable {
  case neutral, accent, success, warning, danger

  var tint: NSColor {
    switch self {
    case .neutral: .secondaryLabelColor
    case .accent: .controlAccentColor
    case .success: .systemGreen
    case .warning: .systemOrange
    case .danger: .systemRed
    }
  }
}

/// A short tinted label: a card's state, a review's verdict, a finding's priority.
struct RichBlockChip: Codable, Hashable {
  var text: String
  var tone: RichBlockChipTone
  var frame: CGRect
}

/// A card's chrome: background, icon, header and chip. Its body blocks are ordinary nodes
/// laid out inside its frame, then its buttons as a `RichBlockAgentActionsNode`.
struct RichBlockAgentCardNode: Codable, Hashable {
  var kind: RichBlockAgentCardKind
  var symbolName: String?
  var iconFrame: CGRect?
  /// The block's own title, or a fixed one such as "Plan" in `titleLiteral`.
  var title: RichBlockTextRange?
  var titleLiteral: String?
  var titleFrame: CGRect?
  var chip: RichBlockChip?
  /// An approval's command, drawn monospaced and left to right in a box.
  var command: RichBlockTextRange?
  var commandFrame: CGRect?
  var commandBoxFrame: CGRect?
  var isRTL: Bool
}

/// A row of buttons inside a block, or the line that replaced them once decided.
struct RichBlockAgentActionsNode: Codable, Hashable {
  enum Style: String, Codable, Hashable { case standard, primary, destructive, link }

  enum Effect: Codable, Hashable {
    /// Runs the message action with this ID through the message's action pipeline.
    case action(String)
    /// Toggles the disclosure state of the block at this path, such as a long plan.
    case toggle(BlockContentPath, expanded: Bool)
    /// Opens a chat the block points at, such as a started task's thread.
    case open(chatID: Int64?, userID: Int64?)
  }

  struct Button: Codable, Hashable {
    var title: String
    var style: Style
    var effect: Effect
    var frame: CGRect
  }

  var buttons: [Button]
  var note: String?
  var noteFrame: CGRect?
  /// A state such as "Waiting on you", trailing the buttons.
  var chip: RichBlockChip?
  var isRTL: Bool
}

struct RichBlockReviewNode: Codable, Hashable {
  struct Finding: Codable, Hashable {
    var priority: RichBlockChip?
    var title: RichBlockTextRange
    var titleFrame: CGRect
    var location: String?
    var locationFrame: CGRect?
    var body: RichBlockTextRange?
    var bodyFrame: CGRect?
    var outcomeSymbol: String?
    var outcomeFrame: CGRect?
    var separatorY: CGFloat?
    /// The finding's own action, such as "Fix".
    var action: RichBlockAgentActionsNode.Button?
  }

  var iconFrame: CGRect
  var title: RichBlockTextRange?
  var titleLiteral: String?
  var titleFrame: CGRect
  var chip: RichBlockChip?
  var summary: RichBlockTextRange?
  var summaryFrame: CGRect?
  var findings: [Finding]
  var isRTL: Bool
}

struct RichBlockPromptChipsNode: Codable, Hashable {
  struct Chip: Codable, Hashable {
    var label: RichBlockTextRange
    /// Composer text; the label's text when the sender gave none.
    var text: String
    var frame: CGRect
    var labelFrame: CGRect
  }

  var chips: [Chip]
  var isRTL: Bool
}
