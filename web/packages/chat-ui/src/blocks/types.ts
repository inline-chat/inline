/**
 * The rich block render model: a tree built from a message's `blocks`
 * projection and its text. Plain, immutable data; views render it.
 *
 * Every node has a `key` that depends only on its kind and its path in the
 * tree, so appending blocks or text keeps every earlier key, and
 * `updateBlockTree` returns the previous object for every unchanged node.
 * `start` and `end` are the UTF-16 span of message text the node covers
 * (both 0 when it covers none).
 */

import type {
  BlockStatus,
  DecisionState,
  DisclosureActivity,
  GrantRequirement,
  PeerRef,
  PhotoInfo,
  ReviewFinding,
} from "@inline/core-protocol"
import type { UserID } from "@inline/ids"
import type { ButtonModel } from "../attachments/buttons"
import type { Direction } from "../direction"
import type { AlbumLayout, Box } from "../media/layout"
import type { FindSpan, TextDocument } from "../text/types"

/**
 * Text of a range, rendered with the existing text model: entities that
 * overlap the range are clipped to it, so links, mentions and styles work
 * inside blocks. Offsets inside `document` are relative to `start`.
 */
export type RichText = {
  readonly start: number
  readonly document: TextDocument
}

type NodeBase = {
  readonly key: string
  readonly start: number
  readonly end: number
}

export type ParagraphBlock = NodeBase & { readonly kind: "paragraph"; readonly text: RichText }
export type HeadingBlock = NodeBase & { readonly kind: "heading"; readonly level: 1 | 2 | 3 | 4 | 5 | 6; readonly text: RichText }
export type FooterBlock = NodeBase & { readonly kind: "footer"; readonly text: RichText }
/** Display math. Inert: rendered as its TeX source, left to right. */
export type MathBlock = NodeBase & { readonly kind: "math"; readonly source: string }
/** Literal text, always left to right; entities inside are ignored. */
export type CodeBlock = NodeBase & {
  readonly kind: "code"
  readonly language: string | undefined
  readonly code: string
  /** Find-in-chat matches inside `code`, relative to it. Absent without highlights. */
  readonly find?: readonly FindSpan[]
}
export type SeparatorBlock = NodeBase & { readonly kind: "separator" }

export type ListMarker =
  | { readonly kind: "bullet" }
  | { readonly kind: "number"; readonly value: number }
  | { readonly kind: "task"; readonly checked: boolean }

export type ListItem = {
  readonly key: string
  readonly marker: ListMarker
  /** "•", "3.", "☑" or "☐". */
  readonly markerText: string
  readonly children: readonly RichBlock[]
}

export type ListBlock = NodeBase & {
  readonly kind: "list"
  readonly ordered: boolean
  readonly dir: Direction | undefined
  readonly items: readonly ListItem[]
}

export type ImageNode = {
  readonly key: string
  readonly state: "pending" | "ready" | "unavailable"
  /** The box to reserve. */
  readonly box: Box
  /** Alt text, plain. */
  readonly alt: string | undefined
  readonly photo: PhotoInfo | undefined
  /** A JPEG to show blurred while pending or loading. */
  readonly preview: Uint8Array | undefined
}

export type ImageBlock = NodeBase & { readonly kind: "image"; readonly image: ImageNode }
export type AlbumBlock = NodeBase & { readonly kind: "album"; readonly images: readonly ImageNode[]; readonly layout: AlbumLayout }

export type DisclosureBlock = NodeBase & {
  readonly kind: "disclosure"
  readonly summary: RichText
  readonly style: "default" | "progress"
  /** Closed unless the sender asked for open. */
  readonly initiallyOpen: boolean
  /**
   * Whether it is open now: the user's toggle (`BlockTreeOptions.openDisclosures`,
   * by `key`), else `initiallyOpen`. Buttons of cards inside count as drawn only when open.
   */
  readonly open: boolean
  readonly activity: DisclosureActivity | undefined
  readonly status: BlockStatus | undefined
  /** A glyph is drawn only for these; running shows as shimmer, done as plain text. */
  readonly statusBadge: "waiting" | "failed" | "cancelled" | undefined
  readonly shimmer: boolean
  /** Hidden while `timer` shows. */
  readonly meta: RichText | undefined
  /** Progress rows show live elapsed time from this date (seconds); see `formatElapsed`. */
  readonly timer: { readonly startedAt: number } | undefined
  readonly dir: Direction | undefined
  readonly children: readonly RichBlock[]
}

export type QuoteBlock = NodeBase & { readonly kind: "quote"; readonly dir: Direction | undefined; readonly children: readonly RichBlock[] }

export type TableCell = { readonly key: string; readonly text: RichText }

export type TableBlock = NodeBase & {
  readonly kind: "table"
  readonly dir: Direction | undefined
  /** Per column. `start` is the text's leading edge. */
  readonly alignments: readonly ("left" | "center" | "right" | "start")[]
  readonly header: readonly TableCell[]
  readonly rows: readonly (readonly TableCell[])[]
}

export type DiffLine = { readonly key: string; readonly kind: "hunk" | "add" | "delete" | "context"; readonly text: string }

export type DiffBlock = NodeBase & {
  readonly kind: "diff"
  readonly path: string
  readonly previousPath: string | undefined
  readonly change: "added" | "modified" | "deleted" | "renamed"
  readonly additions: number | undefined
  readonly deletions: number | undefined
  readonly language: string | undefined
  /** At most 400 lines. */
  readonly lines: readonly DiffLine[]
  readonly hiddenLines: number
  /** "12 more lines", or "Diff shortened by the agent". */
  readonly footer: string | undefined
}

export type FieldRow = {
  readonly key: string
  readonly label: RichText
  /** Rich value, unless `monospace`. */
  readonly value: RichText | undefined
  /** Plain value for monospace fields (commands, paths, IDs): left to right. */
  readonly code: string | undefined
}

export type FieldsBlock = NodeBase & { readonly kind: "fields"; readonly dir: Direction | undefined; readonly fields: readonly FieldRow[] }

export type StepRow = {
  readonly key: string
  readonly text: RichText
  readonly status: BlockStatus | undefined
  readonly detail: RichText | undefined
}

export type StepsBlock = NodeBase & {
  readonly kind: "steps"
  readonly dir: Direction | undefined
  /** A top-level steps block draws as a card. */
  readonly card: boolean
  readonly steps: readonly StepRow[]
}

export type CalloutBlock = NodeBase & {
  readonly kind: "callout"
  readonly tone: "info" | "success" | "warning" | "error"
  readonly title: RichText | undefined
  readonly dir: Direction | undefined
  readonly children: readonly RichBlock[]
}

export type MeterBlock = NodeBase & {
  readonly kind: "meter"
  readonly label: RichText
  readonly value: number
  readonly max: number
  /** `value / max` clamped to [0, 1]. */
  readonly fraction: number
  readonly meta: RichText | undefined
  readonly tone: "normal" | "warning" | "critical"
}

export type FormOptionNode = {
  readonly key: string
  readonly optionId: string
  readonly label: RichText
  readonly description: RichText | undefined
  readonly preview: string | undefined
  readonly recommended: boolean
}

export type FormFieldInput =
  | {
      readonly kind: "select"
      readonly options: readonly FormOptionNode[]
      readonly multiple: boolean
      /** A single choice with more than 6 options is a menu ("Choose…"). */
      readonly presentation: "list" | "menu"
      readonly defaultOptionIds: readonly string[]
      /** Offer "Other" with a "Your answer" field. */
      readonly allowOther: boolean
    }
  | {
      readonly kind: "text"
      readonly style: "singleLine" | "multiline" | "secret"
      readonly placeholder: string | undefined
      /** Never set for a secret field. */
      readonly defaultValue: string | undefined
      readonly maxLength: number | undefined
    }
  | { readonly kind: "toggle"; readonly defaultValue: boolean }
  | {
      readonly kind: "number"
      readonly defaultValue: number | undefined
      readonly min: number | undefined
      readonly max: number | undefined
      readonly step: number
      readonly integer: boolean
    }

export type FormFieldNode = {
  readonly key: string
  readonly fieldId: string
  readonly label: RichText
  /** The label as plain text, for messages such as "Answer “Name” first". */
  readonly labelText: string
  readonly header: RichText | undefined
  readonly description: RichText | undefined
  readonly required: boolean
  readonly input: FormFieldInput
}

export type FormBlock = NodeBase & {
  readonly kind: "form"
  readonly formId: string
  readonly title: RichText | undefined
  readonly dir: Direction | undefined
  readonly fields: readonly FormFieldNode[]
  /** "Submit" unless the sender named it. */
  readonly submitLabel: string
  readonly requiredGrant: GrantRequirement | undefined
  /** Answered or withdrawn: read-only, the button reads "Answered", defaults stand as answers. */
  readonly closed: boolean
}

/**
 * A bot's HTML widget, as data only. It renders in a sandboxed frame on a
 * separate registrable domain, with no network; nothing in this package
 * loads it. Show `title` until the host mounts a snapshot or the live frame.
 */
export type WidgetBlock = NodeBase & {
  readonly kind: "widget"
  readonly widgetId: string
  readonly title: RichText
  readonly frame: { readonly kind: "sandboxedFrame"; readonly origin: "separate"; readonly network: "none" }
  /** Height to reserve: the sender's hint, else 240, clamped to 80...2000. */
  readonly height: number
  /** Inline height cap; taller widgets get "Show all". */
  readonly maxInlineHeight: number
  readonly images: readonly ImageNode[]
  readonly requiredGrant: GrantRequirement | undefined
}

/** Shared by agent cards that wait on a decision. */
export type DecisionCard = {
  readonly state: DecisionState | undefined
  /** "Awaiting approval", "Approved", ... (Mac wording). */
  readonly chip: string | undefined
  /** Shown instead of the buttons once decided: "Approved", "Replaced by a newer request", ... */
  readonly note: string | undefined
  /** Buttons are drawn only while pending (or unspecified). */
  readonly buttons: readonly ButtonModel[]
  readonly showButtons: boolean
}

export type PlanProposalBlock = NodeBase &
  DecisionCard & {
    readonly kind: "planProposal"
    readonly title: RichText | undefined
    /** "Plan" when `title` is absent. */
    readonly defaultTitle: string
    readonly dir: Direction | undefined
    readonly children: readonly RichBlock[]
    readonly decidedByUserId: UserID | undefined
    /** Collapse the plan past this many lines ("Show full plan" / "Show less"). */
    readonly collapseAfterLines: number
  }

export type ApprovalBlock = NodeBase &
  DecisionCard & {
    readonly kind: "approval"
    readonly subject: "command" | "fileChange" | "tool" | "permissions" | "network" | undefined
    readonly title: RichText | undefined
    readonly defaultTitle: string
    /** Monospaced, left to right. */
    readonly command: string | undefined
    readonly cwd: string | undefined
    readonly reason: RichText | undefined
    readonly dir: Direction | undefined
    readonly children: readonly RichBlock[]
    readonly decidedByUserId: UserID | undefined
  }

export type ReviewFindingRow = {
  readonly key: string
  readonly title: RichText
  readonly body: RichText | undefined
  readonly priority: ReviewFinding["priority"]
  /** "P0" ... "P3". */
  readonly priorityLabel: string | undefined
  readonly path: string | undefined
  /** "12" or "12-18". */
  readonly lines: string | undefined
  readonly category: string | undefined
  readonly confidence: ReviewFinding["confidence"]
  readonly outcome: ReviewFinding["outcome"]
  readonly button: ButtonModel | undefined
}

export type ReviewBlock = NodeBase & {
  readonly kind: "review"
  readonly title: RichText | undefined
  readonly defaultTitle: string
  readonly verdict: "correct" | "incorrect" | "needsAttention" | undefined
  /** "No findings", "1 finding", "3 findings", "Looks good". */
  readonly chip: string
  readonly summary: RichText | undefined
  readonly dir: Direction | undefined
  readonly findings: readonly ReviewFindingRow[]
}

export type TaskSuggestionBlock = NodeBase &
  DecisionCard & {
    readonly kind: "taskSuggestion"
    readonly title: RichText
    readonly brief: RichText | undefined
    readonly dir: Direction | undefined
    /** "Open thread", once accepted with a started thread. */
    readonly openThread: PeerRef | undefined
  }

export type NextStepBlock = NodeBase & {
  readonly kind: "nextStep"
  readonly recap: RichText
  readonly question: RichText | undefined
  readonly dir: Direction | undefined
  /** Always drawn. */
  readonly buttons: readonly ButtonModel[]
  readonly blocking: boolean
  /** "Waiting on you" when blocking. */
  readonly chip: string | undefined
}

export type PromptChip = {
  readonly key: string
  readonly label: RichText
  /** What goes in the composer (after any draft, never sent): `text`, else the label. */
  readonly composeText: string
}

export type PromptSuggestionsBlock = NodeBase & {
  readonly kind: "promptSuggestions"
  readonly dir: Direction | undefined
  readonly prompts: readonly PromptChip[]
}

/** A block that could not be drawn: the message text it covers, rendered as text. */
export type FallbackBlock = NodeBase & { readonly kind: "fallback"; readonly text: RichText }

export type RichBlock =
  | ParagraphBlock
  | HeadingBlock
  | FooterBlock
  | MathBlock
  | CodeBlock
  | SeparatorBlock
  | ListBlock
  | ImageBlock
  | AlbumBlock
  | DisclosureBlock
  | QuoteBlock
  | TableBlock
  | DiffBlock
  | FieldsBlock
  | StepsBlock
  | CalloutBlock
  | MeterBlock
  | FormBlock
  | WidgetBlock
  | PlanProposalBlock
  | ApprovalBlock
  | ReviewBlock
  | TaskSuggestionBlock
  | NextStepBlock
  | PromptSuggestionsBlock
  | FallbackBlock

export type RichBlockKind = RichBlock["kind"]

export type BlockTree = {
  readonly kind: "blockTree"
  /** The message text the tree was built from. */
  readonly text: string
  readonly blocks: readonly RichBlock[]
  /**
   * Action IDs drawn by agent cards in this tree; leave them out of the
   * message's button rows (`buttonRowsModel(actions, new Set(claimed))`).
   */
  readonly claimedActionIds: readonly string[]
}
