/**
 * Per-message state for `MessageContent`, created once per row view
 * (`useModel`) and shared by its blocks: the model memo, the disclosure
 * toggles and the buttons in flight. Its identity is the "context" every
 * memoized block view compares, so it changes only with the environment, the
 * row ID or the bubble tone.
 */

import type { MessageRow, MessageRowId } from "@inline/core-protocol"
import { ActionRunner } from "./buttons"
import { ContentMemo, DisclosureState } from "./content-memo"
import type { ContentEnv } from "./env"
import type { MediaOwner } from "./sources"

/** The bubble the content sits in: others' (secondary) or the viewer's (accent). */
export type ContentTone = "incoming" | "outgoing"

export class RowContent {
  readonly memo = new ContentMemo()
  readonly disclosures = new DisclosureState()
  readonly runner = new ActionRunner()
  #owner: MediaOwner | undefined

  constructor(
    readonly env: ContentEnv,
    readonly rowId: MessageRowId,
    readonly tone: ContentTone,
  ) {}

  /**
   * Who the row's media belongs to, for the media layer. The same object while
   * the fields it carries are unchanged, so memoized media views re-render
   * only when the message gets its ID, finishes or fails its upload.
   */
  mediaOwner(message: MessageRow): MediaOwner {
    const previous = this.#owner
    const attachmentId = message.upload?.attachmentId
    if (
      previous &&
      previous.chatId === message.chatId &&
      previous.messageId === message.messageId &&
      previous.attachmentId === attachmentId &&
      previous.clientKey === message.clientKey &&
      previous.state === message.state
    ) {
      return previous
    }
    const owner: MediaOwner = {
      chatId: message.chatId,
      messageId: message.messageId,
      attachmentId,
      clientKey: message.clientKey,
      state: message.state,
    }
    this.#owner = owner
    return owner
  }

  dispose(): void {
    this.runner.dispose()
  }
}
