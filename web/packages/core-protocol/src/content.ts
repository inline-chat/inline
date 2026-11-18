/**
 * Message content beyond text and entities: media, attachments, headers,
 * service events, bot buttons and rich blocks.
 *
 * Plain, structured-cloneable data shaped after `proto/core.proto`, with
 * branded ID strings instead of int64 and string unions instead of enums. The
 * core fills these from its replica (`client/src/queries/content.ts`); the UI
 * builds render models from them (`chat-ui`). Nothing here is a protobuf type.
 *
 * Conventions:
 * - Optional fields are omitted, never `undefined`.
 * - A value the proto calls "unspecified" is omitted.
 * - A oneof the core does not know becomes `{ kind: "unknown" }`, so the UI
 *   can fall back (usually to the message text) instead of dropping it.
 * - Text inside blocks is a `TextRange` into `MessageRow.text`: UTF-16 code
 *   units, as entities are. The core does not check ranges against the text;
 *   the render model does.
 */

import type { ChatID, FileID, InlineID, MessageID, PhotoID, UserID } from "@inline/ids"

// ---------------------------------------------------------------------------
// Shared

/** A chat or user, as `Peer` in the proto. */
export type PeerRef = { kind: "chat"; chatId: ChatID } | { kind: "user"; userId: UserID }

// ---------------------------------------------------------------------------
// Media (`MessageMedia`, `Photo`, `Video`, `Document`, `Voice`)

/**
 * One stored size of a photo (`PhotoSize`), never the stripped one.
 *
 * `cdnUrl` is the URL the server sent. It is signed and expires: a row read
 * back from the replica may carry one that has already expired. The media
 * layer must treat it as a hint, never as a cache key, and refresh on failure
 * (by `fileUniqueId` through `getFilePart`, or by fetching the message again).
 */
export type PhotoSizeInfo = {
  /** Size class: `b` (140 box), `c` (320), `d` (800), `f` (2560), or another letter. */
  type: string
  width: number
  height: number
  /** Bytes, when known. */
  size?: number
  fileUniqueId?: string
  cdnUrl?: string
}

export type PhotoInfo = {
  id: PhotoID
  /** Seconds since the epoch. */
  date?: number
  format?: "jpeg" | "png"
  fileUniqueId?: string
  /** Every stored size except the stripped one, in the server's order. */
  sizes: PhotoSizeInfo[]
  /**
   * The stripped thumbnail (`s` size): a version byte (1), height, width,
   * then a JPEG body without its header. A few hundred bytes. `chat-ui`
   * (`strippedJpeg`) rebuilds a JPEG from it for the first frame.
   */
  stripped?: Uint8Array
  /**
   * A complete tiny JPEG (a few hundred bytes) for the first frame. Set only
   * on the local media of a send from this device (`localMedia`), whose
   * attachment has no stripped bytes; show it the way `stripped` is shown.
   */
  preview?: Uint8Array
}

export type VideoInfo = {
  id: FileID
  /** Seconds since the epoch. */
  date?: number
  width: number
  height: number
  /** Seconds. */
  duration: number
  /** Bytes. */
  size: number
  thumbnail?: PhotoInfo
  /** Signed and expiring; see `PhotoSizeInfo`. */
  cdnUrl?: string
  fileUniqueId?: string
  /** GIF-style animation stored as video: plays muted and loops. */
  animated?: true
  hasAudio?: boolean
}

export type DocumentInfo = {
  id: FileID
  date?: number
  fileName: string
  mimeType: string
  /** Bytes. */
  size: number
  thumbnail?: PhotoInfo
  /** Signed and expiring; see `PhotoSizeInfo`. */
  cdnUrl?: string
  fileUniqueId?: string
}

export type VoiceInfo = {
  id: FileID
  date?: number
  /** Seconds. */
  duration: number
  /** Bytes. */
  size: number
  mimeType: string
  /** Samples 0 to 255, for the waveform. */
  waveform?: Uint8Array
  /** Signed and expiring; see `PhotoSizeInfo`. */
  cdnUrl?: string
  fileUniqueId?: string
}

/**
 * A message's media. `sticker` is the message's `is_sticker` flag, carried on
 * the visual kinds it applies to.
 */
export type MediaContent =
  | { kind: "photo"; photo: PhotoInfo; sticker?: true }
  | { kind: "video"; video: VideoInfo; sticker?: true }
  | { kind: "document"; document: DocumentInfo }
  | { kind: "voice"; voice: VoiceInfo }
  /** A nudge; the message text holds its emoji. */
  | { kind: "nudge" }

// ---------------------------------------------------------------------------
// Attachments (`MessageAttachment`)

export type UrlPreviewMediaContent =
  | { kind: "photo"; photo: PhotoInfo }
  | { kind: "video"; video: VideoInfo }
  | { kind: "document"; document: DocumentInfo }
  /** A remote stream the server validated but does not host. Pass `url` through `safeLink`. */
  | { kind: "externalVideo"; url: string; mimeType?: string; width?: number; height?: number; duration?: number }
  /** A provider player. Never framed by the message view; open `url` instead. */
  | { kind: "embed"; url: string; type?: string; width?: number; height?: number; duration?: number }

export type UrlPreviewMediaType = "article" | "image" | "video" | "document" | "embed"

/** Every URL here is from the sender's content: pass it through `safeLink` before use. */
export type UrlPreviewAttachment = {
  kind: "urlPreview"
  /** Attachment ID. */
  id: InlineID
  /** The preview's own ID. */
  previewId?: InlineID
  url?: string
  /** Sanitized URL text for display only, never a fetch target. */
  displayUrl?: string
  siteName?: string
  title?: string
  description?: string
  /** Stable provider key, such as `youtube` or `loom`. */
  provider?: string
  author?: string
  iconEmoji?: string
  /** Seconds. */
  duration?: number
  mediaType?: UrlPreviewMediaType
  photo?: PhotoInfo
  authorPhoto?: PhotoInfo
  media?: UrlPreviewMediaContent
  layout?: { hasLargeMedia: boolean; showLargeMedia: boolean }
}

export type ExternalTaskStatus = "backlog" | "todo" | "inProgress" | "done" | "cancelled"

export type ExternalTaskAttachment = {
  kind: "externalTask"
  id: InlineID
  /** The task's ID in our database. */
  taskRecordId?: InlineID
  /** The task's ID in the external application. */
  taskId: string
  application: string
  title: string
  status?: ExternalTaskStatus
  assigneeUserId?: UserID
  /** Pass through `safeLink`. */
  url?: string
  number?: string
  /** Seconds since the epoch. */
  date?: number
}

export type MessageAttachmentContent =
  | UrlPreviewAttachment
  | ExternalTaskAttachment
  | { kind: "unknown"; id: InlineID }

// ---------------------------------------------------------------------------
// Headers and footers

/** `MessageFwdHeader`: where a forwarded message came from. */
export type ForwardHeader = {
  fromPeer?: PeerRef
  /** The original sender. */
  fromUserId?: UserID
  /** The original message, in `fromPeer`'s chat. */
  fromMessageId?: MessageID
}

/**
 * The reply thread under a message: `MessageSubthread` when present, else
 * `MessageReplies` (as `kind: "reply"`).
 */
export type RepliesSummary = {
  kind: "reply" | "subthread"
  /** The child chat. */
  chatId: ChatID
  /** Messages in the child chat. */
  count: number
  hasUnread: boolean
  /** Newest first, distinct, limited by the server. */
  recentUserIds: UserID[]
  /** Subthread title. */
  title?: string
}

/** `MessageVia`: who sent the message for its sender ("Sent via ..."). */
export type ViaInfo =
  /** A known agent ID such as `claude-code`, `codex` or `agent`. */
  | { kind: "app"; app: string; name?: string }
  /** A bot the sender owns. */
  | { kind: "bot"; botUserId: UserID; name?: string }

// ---------------------------------------------------------------------------
// Service messages (`MessageService`)

export type GridTranscriptEvent = "turn" | "started" | "stopped" | "interrupted" | "link"

/**
 * A service event. `unknown` is an event this build does not know: show the
 * message text as a service row.
 */
export type ServiceContent =
  | { kind: "threadBacklink"; sourceChatId?: ChatID; sourceTitle?: string }
  | { kind: "pinnedMessage"; messageId?: MessageID }
  | {
      kind: "gridTranscript"
      runId: string
      segmentId: string
      speakerUserId?: UserID
      event: GridTranscriptEvent
    }
  | { kind: "unknown" }

// ---------------------------------------------------------------------------
// Bot buttons (`MessageActions`)

/** What a viewer needs on the sending bot (`AgentGrantRequirement`). Absent means anyone. */
export type GrantRequirement = "access" | "invoke" | "steer" | "approve" | "configure" | "owner" | "unknown"

export type MessageActionKind =
  /** Invoke the bot with `actionId`; its opaque payload stays on the server side. */
  | { kind: "callback" }
  | { kind: "copyText"; text: string }
  /** Pass through `safeLink`; a non-web scheme is confirmed first. */
  | { kind: "openUrl"; url: string }
  | { kind: "openLink"; peer: PeerRef; messageId?: MessageID }
  /** Put `text` in the composer after any draft; never send. */
  | { kind: "compose"; text: string }
  | { kind: "unknown" }

export type MessageActionButton = {
  actionId: string
  text: string
  style: "default" | "primary" | "destructive"
  action: MessageActionKind
  confirm?: { title: string; text?: string; confirmText?: string }
  requiredGrant?: GrantRequirement
}

/** Rows of buttons, in order. */
export type MessageActionRows = MessageActionButton[][]

// ---------------------------------------------------------------------------
// Rich blocks (`BlockContent`, `Block`)

/** UTF-16 range into `MessageRow.text`, with the server's first-strong direction. */
export type TextRange = { offset: number; length: number; rtl?: boolean }

/** `BlockStatus`; absent means unspecified (no status shown). */
export type BlockStatus = "pending" | "running" | "waiting" | "done" | "failed" | "cancelled"

/** `BlockDecisionState`; absent means unspecified. */
export type DecisionState = "pending" | "accepted" | "declined" | "expired" | "superseded"

export type BlockImageInfo = {
  alt?: TextRange
  state: "pending" | "ready" | "unavailable" | "unknown"
  /** Set when ready. */
  photo?: PhotoInfo
  /** From `pending` or `unavailable`; for `ready` the photo's sizes say. */
  width?: number
  height?: number
  /** Pending images may carry a stripped thumbnail; see `PhotoInfo.stripped`. */
  stripped?: Uint8Array
}

export type ListItemBlock = {
  children: ContentBlock[]
  /** Present for a task-list item. */
  checked?: boolean
}

export type DisclosureActivity =
  | "reasoning"
  | "explore"
  | "read"
  | "search"
  | "edit"
  | "delete"
  | "move"
  | "command"
  | "web"
  | "tool"
  | "agent"

export type TableAlignment = "left" | "center" | "right"

export type FormOption = {
  optionId: string
  label?: TextRange
  description?: TextRange
  preview?: TextRange
  recommended: boolean
}

export type FormInput =
  | {
      kind: "select"
      options: FormOption[]
      multiple: boolean
      defaultOptionIds: string[]
      allowOther: boolean
    }
  | {
      kind: "text"
      /** A `secret` field never carries a default; its answers are never shown back or stored. */
      style: "singleLine" | "multiline" | "secret"
      placeholder?: string
      defaultValue?: string
      maxLength?: number
    }
  | { kind: "toggle"; defaultValue: boolean }
  | { kind: "number"; defaultValue?: number; min?: number; max?: number; step?: number; integer: boolean }
  | { kind: "unknown" }

export type FormField = {
  fieldId: string
  label?: TextRange
  description?: TextRange
  header?: TextRange
  required: boolean
  input: FormInput
}

export type ReviewFinding = {
  title?: TextRange
  body?: TextRange
  priority?: "p0" | "p1" | "p2" | "p3"
  path?: TextRange
  startLine?: number
  endLine?: number
  category?: string
  confidence?: "confirmed" | "plausible"
  outcome?: "fixed" | "skipped" | "noChangeNeeded"
  actionId?: string
}

/**
 * One block. Fields mirror the proto message of the same name; required
 * text ranges are optional here because a malformed one is dropped rather
 * than thrown on, and the render model falls back to the text it covers.
 */
export type ContentBlock =
  | { kind: "paragraph"; text?: TextRange }
  | { kind: "heading"; text?: TextRange; level: number }
  | { kind: "code"; text?: TextRange; language?: string }
  | { kind: "list"; style?: "unordered" | "ordered"; start?: number; items: ListItemBlock[]; rtl?: boolean }
  | { kind: "separator" }
  | { kind: "image"; image: BlockImageInfo }
  | { kind: "album"; images: BlockImageInfo[] }
  | {
      kind: "disclosure"
      summary?: TextRange
      style: "default" | "progress"
      initiallyOpen?: boolean
      children: ContentBlock[]
      rtl?: boolean
      activity?: DisclosureActivity
      status?: BlockStatus
      meta?: TextRange
      /** Seconds since the epoch. */
      startedAt?: number
    }
  | { kind: "footer"; text?: TextRange }
  | { kind: "quote"; children: ContentBlock[]; rtl?: boolean }
  | {
      kind: "table"
      /** The first row is the header. */
      rows: TextRange[][]
      /** Per column; absent entries mean the text's leading edge. */
      alignments: (TableAlignment | undefined)[]
      rtl?: boolean
    }
  | { kind: "math"; text?: TextRange }
  | {
      kind: "diff"
      path?: TextRange
      text?: TextRange
      change?: "added" | "modified" | "deleted" | "renamed"
      previousPath?: TextRange
      additions?: number
      deletions?: number
      language?: string
      truncated?: boolean
    }
  | { kind: "fields"; fields: { label?: TextRange; value?: TextRange; monospace: boolean }[]; rtl?: boolean }
  | { kind: "steps"; steps: { text?: TextRange; status?: BlockStatus; detail?: TextRange }[]; rtl?: boolean }
  | {
      kind: "callout"
      tone?: "info" | "success" | "warning" | "error"
      title?: TextRange
      children: ContentBlock[]
      rtl?: boolean
    }
  | {
      kind: "meter"
      label?: TextRange
      value: number
      max: number
      meta?: TextRange
      tone?: "warning" | "critical"
    }
  | {
      kind: "form"
      formId: string
      title?: TextRange
      fields: FormField[]
      submitLabel?: string
      requiredGrant?: GrantRequirement
      closed: boolean
      rtl?: boolean
    }
  | {
      /**
       * A bot's HTML widget. Rendered only in a sandboxed frame on a separate
       * registrable domain, never in the app's document. The HTML itself is
       * deliberately not on the row (see the README); `htmlLength` says
       * whether there is any.
       */
      kind: "widget"
      widgetId: string
      title?: TextRange
      /** UTF-16 length of the HTML. */
      htmlLength: number
      /** Measured height hint in CSS px at 640 px wide. */
      height?: number
      images: BlockImageInfo[]
      requiredGrant?: GrantRequirement
    }
  | {
      kind: "planProposal"
      title?: TextRange
      children: ContentBlock[]
      state?: DecisionState
      actionIds: string[]
      decidedByUserId?: UserID
      rtl?: boolean
    }
  | {
      kind: "approval"
      subject?: "command" | "fileChange" | "tool" | "permissions" | "network"
      title?: TextRange
      command?: TextRange
      cwd?: TextRange
      reason?: TextRange
      children: ContentBlock[]
      state?: DecisionState
      actionIds: string[]
      decidedByUserId?: UserID
      rtl?: boolean
    }
  | {
      kind: "review"
      title?: TextRange
      verdict?: "correct" | "incorrect" | "needsAttention"
      summary?: TextRange
      findings: ReviewFinding[]
      rtl?: boolean
    }
  | {
      kind: "taskSuggestion"
      title?: TextRange
      brief?: TextRange
      state?: DecisionState
      startedPeer?: PeerRef
      /** Seconds since the epoch. */
      expiresAt?: number
      actionIds: string[]
      rtl?: boolean
    }
  | {
      kind: "nextStep"
      recap?: TextRange
      question?: TextRange
      actionIds: string[]
      blocking: boolean
      rtl?: boolean
    }
  | { kind: "promptSuggestions"; prompts: { label?: TextRange; text?: string }[]; rtl?: boolean }
  /** A kind this build does not know. The UI shows the text it covers. */
  | { kind: "unknown" }

export type ContentBlockKind = ContentBlock["kind"]
