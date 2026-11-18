/**
 * The text render model: a small immutable tree built from a message's text
 * and entities. Views render it; nothing in it is framework-bound.
 *
 * Offsets (`start`, `end`) are UTF-16 code units into the message text, end
 * exclusive. Keys are stable while text is appended (see `reuse.ts`).
 */

import type { Entity } from "@inline/core-protocol"
import type { ChatID, SpaceID, UserID } from "@inline/ids"
import type { Direction } from "../direction"
import type { SafeLink } from "../links"

// MARK: - Input

/**
 * A message entity as this package reads it: the core-protocol `Entity` plus
 * the fields `proto/core.proto` (`MessageEntity`) carries that the contract
 * does not have yet. Every field is validated at runtime; anything malformed
 * degrades to plain text.
 *
 * TODO(contract): add to `Entity` in `@inline/core-protocol`: `groupId`
 * (group mention), `spaceId` and `title` (thread title), `botUserId` (bot
 * command), `agentId` (mention), `display` (math).
 */
export type EntityInput = Entity & {
  readonly groupId?: string
  readonly spaceId?: SpaceID
  readonly title?: string
  readonly botUserId?: UserID
  readonly agentId?: string
  readonly display?: boolean
}

// MARK: - Inline nodes

/**
 * Range styles. A run carries them in this canonical order. `find` is not an
 * entity: it marks a find-in-chat match (`highlightTextDocument`) and renders
 * outermost, as `<mark data-kind="find">`.
 */
export type Mark = "find" | "bold" | "italic" | "underline" | "strikethrough" | "highlight" | "code"
export const markOrder: readonly Mark[] = ["find", "bold", "italic", "underline", "strikethrough", "highlight", "code"]

/**
 * A find-in-chat range: UTF-16 `[start, end)` into the message's text, as
 * `{ start, end }` or `[start, end]`.
 */
export type HighlightRange = { readonly start: number; readonly end: number } | readonly [start: number, end: number]

/** A normalized highlight span, relative to the node it sits on. */
export type FindSpan = { readonly start: number; readonly end: number }

/**
 * A run of text with one set of marks. Text may contain `\n` (a line break
 * inside a paragraph); views render paragraphs with `white-space: pre-wrap`.
 */
export type TextRun = {
  readonly kind: "text"
  readonly key: string
  readonly start: number
  readonly end: number
  readonly text: string
  /** Interned: equal mark sets are the same array. */
  readonly marks: readonly Mark[]
}

export type LinkSource = "url" | "textUrl" | "email" | "phoneNumber"

/** A link that passed `safeLink`. Unsafe links are never nodes; their text stays as runs. */
export type LinkNode = {
  readonly kind: "link"
  readonly key: string
  readonly start: number
  readonly end: number
  readonly source: LinkSource
  readonly link: SafeLink
  readonly children: readonly TextRun[]
}

export type MentionTarget =
  | { readonly kind: "user"; readonly userId: UserID; readonly agentId?: string }
  | { readonly kind: "username"; readonly username: string }
  /** `groupId` is absent until the contract carries it. */
  | { readonly kind: "group"; readonly groupId?: string }

export type MentionNode = {
  readonly kind: "mention"
  readonly key: string
  readonly start: number
  readonly end: number
  readonly target: MentionTarget
  readonly children: readonly TextRun[]
}

export type ThreadTarget =
  | { readonly kind: "chat"; readonly chatId: ChatID }
  | { readonly kind: "title"; readonly spaceId: SpaceID; readonly title: string }

export type ThreadRefNode = {
  readonly kind: "threadRef"
  readonly key: string
  readonly start: number
  readonly end: number
  readonly target: ThreadTarget
  readonly children: readonly TextRun[]
}

export type BotCommandNode = {
  readonly kind: "botCommand"
  readonly key: string
  readonly start: number
  readonly end: number
  /** The command as written, with its slash: `/help`. */
  readonly command: string
  readonly botUserId?: UserID
  readonly children: readonly TextRun[]
}

/** Inline TeX source. Inert for now: rendered as its source. */
export type MathNode = {
  readonly kind: "math"
  readonly key: string
  readonly start: number
  readonly end: number
  readonly source: string
}

export type ContainerNode = LinkNode | MentionNode | ThreadRefNode | BotCommandNode
export type InlineNode = TextRun | ContainerNode | MathNode
export type InlineKind = InlineNode["kind"]

// MARK: - Block nodes

type BlockBase = {
  readonly key: string
  readonly start: number
  readonly end: number
  /** Empty lines between the previous block and this one (0 for the first). */
  readonly blankLinesBefore: number
}

export type ParagraphNode = BlockBase & {
  readonly kind: "paragraph"
  /** Undefined when the paragraph has no letters: render `dir="auto"` or inherit. */
  readonly dir: Direction | undefined
  readonly children: readonly InlineNode[]
}

/** A `pre` entity. Its text is literal: entities inside it are not rendered. */
export type CodeBlockNode = BlockBase & {
  readonly kind: "codeBlock"
  /** A sanitized language tag (`[A-Za-z0-9_+#.-]{1,32}`), or undefined. */
  readonly language: string | undefined
  readonly text: string
  /** Find-in-chat matches inside the code, relative to `text`. Absent without highlights. */
  readonly find?: readonly FindSpan[]
}

/** A `blockquote` entity that owns whole lines. Blank lines inside split paragraphs. */
export type QuoteNode = BlockBase & {
  readonly kind: "quote"
  readonly dir: Direction | undefined
  readonly children: readonly ParagraphNode[]
}

/** A display math entity on its own line. Inert for now. */
export type MathBlockNode = BlockBase & {
  readonly kind: "mathBlock"
  readonly source: string
}

/**
 * Block kinds. Open for extension: media, rich blocks, link previews and
 * widgets attach as new kinds here, produced by their own builders and
 * composed with the text blocks into one document. Views must render an
 * unknown kind as nothing (or a text fallback), never throw.
 */
export type BlockNode = ParagraphNode | CodeBlockNode | QuoteNode | MathBlockNode
export type BlockKind = BlockNode["kind"]

export type TextDocument = {
  readonly kind: "document"
  /** The message text the document was built from. */
  readonly text: string
  /** The whole message's direction, or undefined when it has no letters. */
  readonly dir: Direction | undefined
  readonly blocks: readonly BlockNode[]
}
