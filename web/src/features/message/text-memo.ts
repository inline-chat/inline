/**
 * The per-row text memo. A row keeps one of these for its lifetime and reads
 * its text document through it, so a message that streams in (its text
 * growing many times a second) is rebuilt with `updateTextDocument`, which
 * keeps the identity of every unchanged block and inline node. The memoized
 * text view then re-renders only the node that grew.
 *
 * Keyed by row identity (`MessageRow.id`, stable across the send
 * acknowledgement): a memo handed a different row starts over instead of
 * reusing another message's nodes.
 */

import type { MessageRow } from "@inline/core-protocol"
import { type TextDocument, updateTextDocument } from "@inline/chat-ui"
import { emojiSize, type EmojiSize } from "./emoji"

export type MessageTextSource = Pick<MessageRow, "id" | "text" | "entities">

export type MessageTextContent = {
  readonly document: TextDocument
  /** Emoji-only size class of the text (the row decides whether it applies). */
  readonly emoji: EmojiSize
}

export class MessageTextMemo {
  #rowId: string | undefined
  #text: string | undefined
  #entities: MessageRow["entities"]
  #content: MessageTextContent | undefined
  #builds = 0

  /**
   * The text content for `row`. Returns the previous object while the text
   * and entities are unchanged, so `===` tells a view nothing changed.
   */
  read(row: MessageTextSource): MessageTextContent {
    const content = this.#content
    if (content && this.#rowId === row.id && this.#text === row.text && this.#entities === row.entities) return content

    const previous = this.#rowId === row.id ? content : undefined
    const document = updateTextDocument(previous?.document, row.text, row.entities)
    const emoji = previous && previous.document.text === document.text ? previous.emoji : emojiSize(document.text)
    const next: MessageTextContent =
      previous && previous.document === document && previous.emoji === emoji ? previous : { document, emoji }

    this.#rowId = row.id
    this.#text = row.text
    this.#entities = row.entities
    this.#content = next
    if (next !== previous) this.#builds += 1
    return next
  }

  /** How many distinct contents this memo produced. For tests and the lab. */
  get builds(): number {
    return this.#builds
  }
}

export const createMessageTextMemo = (): MessageTextMemo => new MessageTextMemo()
