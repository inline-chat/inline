import CoreGraphics
import Foundation

// MARK: - Shared pieces

/// Progress of a step, as the protocol's block status.
public enum RichStatus: Hashable, Sendable {
  case pending
  case running
  /// Blocked on a person.
  case waiting
  case done
  case failed
  case cancelled
}

/// A color by meaning. The host maps it to its palette for light and dark.
public enum RichTone: Hashable, Sendable {
  case neutral
  case accent
  case success
  /// Orange: needs attention.
  case warning
  /// Yellow: worth a look.
  case caution
  case critical
}

/// A glyph in an agent block.
public enum RichSymbol: Hashable, Sendable {
  /// An SF Symbol by name.
  case named(String, tone: RichTone)
  /// A step's marker: a spinner while running, a dashed circle while pending, a check once done.
  case status(RichStatus)
}

/// What tapping part of an agent block does. The host performs it.
public enum RichTap: Hashable, Sendable {
  /// Runs `Message.actions[id]` through the message's action pipeline.
  case action(id: String)
  /// Puts the text in the chat's composer. Never sends.
  case compose(String)
  /// Opens or closes the content at `path`; `isExpanded` is the state the tap leaves it in.
  case toggle(RichPath, isExpanded: Bool)
  /// Opens a thread or a direct chat.
  case openThread(id: Int64)
  case openUser(id: Int64)
}

/// A small capsule with a short label: a plan's state, a finding's priority, a verdict.
public struct RichChip: Hashable, Sendable {
  public var text: MessageText
  public var tone: RichTone
  /// SF Symbol drawn before the text.
  public var symbol: String?

  public init(text: MessageText, tone: RichTone, symbol: String? = nil) {
    self.text = text
    self.tone = tone
    self.symbol = symbol
  }
}

/// A button inside a block. Message actions keep their style; suggestions are outlined capsules.
public struct RichButton: Hashable, Sendable {
  public enum Style: Hashable, Sendable {
    case standard
    case primary
    case destructive
    /// An outlined capsule, for prompt suggestions.
    case suggestion
  }

  public var title: MessageText
  public var tap: RichTap
  public var style: Style

  public init(title: MessageText, tap: RichTap, style: Style = .standard) {
    self.title = title
    self.tap = tap
    self.style = style
  }
}

/// A line that replaces a block's buttons once it is decided ("Approved by Mo"), or links to
/// what it started.
public struct RichStatusLine: Hashable, Sendable {
  public var symbol: RichSymbol?
  public var text: MessageText
  public var tap: RichTap?

  public init(symbol: RichSymbol? = nil, text: MessageText, tap: RichTap? = nil) {
    self.symbol = symbol
    self.text = text
    self.tap = tap
  }
}

/// A "Show full plan" or "Show details" row. `label` reads for the current state; the planner
/// leaves it out when there is nothing to show or hide.
public struct RichToggle: Hashable, Sendable {
  public var label: MessageText
  public var tap: RichTap

  public init(label: MessageText, tap: RichTap) {
    self.label = label
    self.tap = tap
  }
}

// MARK: - Inputs

/// A task list or plan: Claude's todo card. Borderless and untitled; each step's marker shows
/// where it stands.
public struct RichSteps: Hashable, Sendable {
  /// More than this and the layout refuses the block; builders fall back to its text first.
  public static let maximumItems = 256
  public struct Item: Hashable, Sendable {
    public var text: MessageText
    /// Secondary line under the step.
    public var detail: MessageText?
    /// Nil draws a pending marker.
    public var status: RichStatus?

    public init(text: MessageText, detail: MessageText? = nil, status: RichStatus?) {
      self.text = text
      self.detail = detail
      self.status = status
    }
  }

  public var items: [Item]
  public var isRightToLeft: Bool

  public init(items: [Item], isRightToLeft: Bool = false) {
    self.items = items
    self.isRightToLeft = isRightToLeft
  }
}

/// Label and value pairs in two columns.
public struct RichFields: Hashable, Sendable {
  /// More than this and the layout refuses the block; builders fall back to its text first.
  public static let maximumRows = 128
  public struct Row: Hashable, Sendable {
    public var label: MessageText
    /// Monospaced values arrive styled so by the host.
    public var value: MessageText

    public init(label: MessageText, value: MessageText) {
      self.label = label
      self.value = value
    }
  }

  public var rows: [Row]
  public var isRightToLeft: Bool

  public init(rows: [Row], isRightToLeft: Bool = false) {
    self.rows = rows
    self.isRightToLeft = isRightToLeft
  }
}

/// A tinted box with an icon, an optional title and its own blocks.
public struct RichCallout: Hashable, Sendable {
  public var tone: RichTone
  public var symbol: String
  public var title: MessageText?
  public var children: [RichBlock]
  public var isRightToLeft: Bool

  public init(tone: RichTone, symbol: String, title: MessageText?, children: [RichBlock], isRightToLeft: Bool = false) {
    self.tone = tone
    self.symbol = symbol
    self.title = title
    self.children = children
    self.isRightToLeft = isRightToLeft
  }
}

/// A label, an optional trailing value and a bar.
public struct RichMeter: Hashable, Sendable {
  public var label: MessageText
  public var meta: MessageText?
  /// 0 through 1.
  public var fraction: Double
  public var tone: RichTone
  public var isRightToLeft: Bool

  public init(label: MessageText, meta: MessageText?, fraction: Double, tone: RichTone, isRightToLeft: Bool = false) {
    self.label = label
    self.meta = meta
    self.fraction = fraction
    self.tone = tone
    self.isRightToLeft = isRightToLeft
  }
}

/// One file's change: a header with the path and counts, and the unified diff, which scrolls
/// sideways like code.
public struct RichDiff: Hashable, Sendable {
  public var symbol: String
  /// Drawn on one line, shortened in the middle.
  public var path: MessageText
  /// "+3 −1", colored by the host.
  public var counts: MessageText?
  /// The diff's lines, monospaced. Lines starting "+" or "-" get a tinted background.
  public var body: MessageText?
  /// "12 more lines".
  public var footer: MessageText?

  public init(symbol: String, path: MessageText, counts: MessageText?, body: MessageText?, footer: MessageText?) {
    self.symbol = symbol
    self.path = path
    self.counts = counts
    self.body = body
    self.footer = footer
  }
}

/// A plan the agent wants approved before it acts.
public struct RichPlanProposal: Hashable, Sendable {
  public var symbol: String
  /// "Plan", or the plan's own title.
  public var title: MessageText
  public var state: RichChip?
  public var children: [RichBlock]
  /// The body shows this much until expanded; its toggle shows only when the body is taller.
  public var collapsedHeight: CGFloat
  public var isExpanded: Bool
  public var toggle: RichToggle?
  /// Shown while undecided.
  public var buttons: [RichButton]
  /// Replaces the buttons once decided.
  public var decision: RichStatusLine?
  public var isRightToLeft: Bool

  public init(
    symbol: String,
    title: MessageText,
    state: RichChip?,
    children: [RichBlock],
    collapsedHeight: CGFloat,
    isExpanded: Bool,
    toggle: RichToggle?,
    buttons: [RichButton],
    decision: RichStatusLine?,
    isRightToLeft: Bool = false
  ) {
    self.symbol = symbol
    self.title = title
    self.state = state
    self.children = children
    self.collapsedHeight = collapsedHeight
    self.isExpanded = isExpanded
    self.toggle = toggle
    self.buttons = buttons
    self.decision = decision
    self.isRightToLeft = isRightToLeft
  }
}

/// A request to run a command, change files, use a tool or widen permissions.
public struct RichApproval: Hashable, Sendable {
  public var symbol: String
  public var title: MessageText
  public var state: RichChip?
  /// Monospaced, in a filled box.
  public var command: MessageText?
  /// Secondary lines under the command: the folder, the reason.
  public var details: [MessageText]
  /// Diffs or fields, hidden until expanded.
  public var children: [RichBlock]
  public var isExpanded: Bool
  public var toggle: RichToggle?
  public var buttons: [RichButton]
  public var decision: RichStatusLine?
  public var isRightToLeft: Bool

  public init(
    symbol: String,
    title: MessageText,
    state: RichChip?,
    command: MessageText?,
    details: [MessageText],
    children: [RichBlock],
    isExpanded: Bool,
    toggle: RichToggle?,
    buttons: [RichButton],
    decision: RichStatusLine?,
    isRightToLeft: Bool = false
  ) {
    self.symbol = symbol
    self.title = title
    self.state = state
    self.command = command
    self.details = details
    self.children = children
    self.isExpanded = isExpanded
    self.toggle = toggle
    self.buttons = buttons
    self.decision = decision
    self.isRightToLeft = isRightToLeft
  }
}

/// Code review notes: a verdict and findings with priority and location.
public struct RichReview: Hashable, Sendable {
  /// More than this and the layout refuses the block; builders fall back to its text first.
  public static let maximumFindings = 200
  public struct Finding: Hashable, Sendable {
    /// "P1", colored by priority.
    public var priority: RichChip?
    public var title: MessageText
    /// "path:12", monospaced.
    public var location: MessageText?
    /// Shown when expanded.
    public var body: MessageText?
    public var isExpanded: Bool
    /// Tapping the row opens or closes the body.
    public var toggle: RichTap?
    /// Fixed, skipped or no change needed.
    public var outcome: RichSymbol?
    public var button: RichButton?

    public init(
      priority: RichChip?,
      title: MessageText,
      location: MessageText?,
      body: MessageText?,
      isExpanded: Bool,
      toggle: RichTap?,
      outcome: RichSymbol?,
      button: RichButton?
    ) {
      self.priority = priority
      self.title = title
      self.location = location
      self.body = body
      self.isExpanded = isExpanded
      self.toggle = toggle
      self.outcome = outcome
      self.button = button
    }
  }

  public var symbol: String
  public var title: MessageText
  public var verdict: RichChip?
  /// "3 findings".
  public var count: MessageText?
  public var summary: MessageText?
  public var findings: [Finding]
  public var isRightToLeft: Bool

  public init(
    symbol: String,
    title: MessageText,
    verdict: RichChip?,
    count: MessageText?,
    summary: MessageText?,
    findings: [Finding],
    isRightToLeft: Bool = false
  ) {
    self.symbol = symbol
    self.title = title
    self.verdict = verdict
    self.count = count
    self.summary = summary
    self.findings = findings
    self.isRightToLeft = isRightToLeft
  }
}

/// Work the agent proposes to run on its own, as a new thread.
public struct RichTaskSuggestion: Hashable, Sendable {
  public var symbol: String
  public var title: MessageText
  public var state: RichChip?
  /// Clamped to `RichLayoutMetrics.briefLineLimit` lines.
  public var brief: MessageText?
  public var buttons: [RichButton]
  /// Replaces the buttons once decided, such as "Started · Open thread".
  public var status: RichStatusLine?
  /// Expired suggestions draw faded.
  public var isMuted: Bool
  public var isRightToLeft: Bool

  public init(
    symbol: String,
    title: MessageText,
    state: RichChip?,
    brief: MessageText?,
    buttons: [RichButton],
    status: RichStatusLine?,
    isMuted: Bool,
    isRightToLeft: Bool = false
  ) {
    self.symbol = symbol
    self.title = title
    self.state = state
    self.brief = brief
    self.buttons = buttons
    self.status = status
    self.isMuted = isMuted
    self.isRightToLeft = isRightToLeft
  }
}

/// The agent's end-of-turn recap and the one decision it waits on.
public struct RichNextStep: Hashable, Sendable {
  public var recap: MessageText
  public var question: MessageText?
  /// "Waiting on you", when the agent is stopped until someone answers.
  public var waiting: RichChip?
  public var buttons: [RichButton]
  public var isRightToLeft: Bool

  public init(recap: MessageText, question: MessageText?, waiting: RichChip?, buttons: [RichButton], isRightToLeft: Bool = false) {
    self.recap = recap
    self.question = question
    self.waiting = waiting
    self.buttons = buttons
    self.isRightToLeft = isRightToLeft
  }
}

/// Chips that put a prompt in the viewer's composer.
public struct RichPromptSuggestions: Hashable, Sendable {
  /// More than this and the layout refuses the block; builders fall back to its text first.
  public static let maximumPrompts = 32
  public var prompts: [RichButton]
  public var isRightToLeft: Bool

  public init(prompts: [RichButton], isRightToLeft: Bool = false) {
    self.prompts = prompts
    self.isRightToLeft = isRightToLeft
  }
}

// MARK: - Layout

public extension RichLayout {
  /// An agent block placed as parts in its node's coordinates. Each kind arranges its own parts;
  /// the host draws them in order, so earlier parts sit behind later ones.
  struct Card: Sendable {
    public enum Style: Hashable, Sendable {
      /// A top-level task list: a rounded card with a hairline border and a subtle fill.
      case taskList
      /// No chrome: fields, meters, prompt suggestions.
      case plain
      case callout(RichTone)
      case plan
      case approval
      case review
      case taskSuggestion
      /// A quiet box.
      case nextStep
    }

    public struct Part: Sendable {
      public enum Kind: Sendable {
        case text(TextLayout)
        /// Fills the frame; a status draws centered at the frame's size.
        case symbol(RichSymbol)
        /// Its symbol, if any, sits at the leading edge inside the padding.
        case chip(TextLayout, tone: RichTone, symbol: String?)
        /// Title centered in the frame.
        case button(TextLayout, style: RichButton.Style)
        /// A filled rounded box, such as behind a command.
        case box
        case bar(fraction: Double, tone: RichTone)
        case separator
        /// A tappable row behind its texts; highlights while pressed.
        case row
      }

      public var kind: Kind
      public var frame: CGRect
      public var tap: RichTap?

      public init(kind: Kind, frame: CGRect, tap: RichTap? = nil) {
        self.kind = kind
        self.frame = frame
        self.tap = tap
      }
    }

    public var style: Style
    public var parts: [Part]
    public var isMuted: Bool
    public var isRightToLeft: Bool
    /// Children placed inside the card, as other nodes: the card's frame encloses them.
    public var hasChildren: Bool
  }

  /// One file's diff: a header row and a body that scrolls sideways.
  struct Diff: Sendable {
    public var symbol: String
    public var symbolFrame: CGRect
    /// The full path; the host draws it on one line in `pathFrame`, shortened in the middle.
    public var path: MessageText
    public var pathFrame: CGRect
    public var counts: TextLayout?
    public var countsFrame: CGRect
    public var copyFrame: CGRect
    public var headerHeight: CGFloat
    /// Unwrapped; one line per diff line.
    public var body: TextLayout?
    /// In the body's scrollable content, below the header.
    public var bodyOrigin: CGPoint
    public var footer: TextLayout?
    public var footerOrigin: CGPoint
    /// Scrollable width of the body.
    public var contentWidth: CGFloat
  }
}
