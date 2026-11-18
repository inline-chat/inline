/**
 * Which parts a row shows, in the Mac's default style (bubble). Mac:
 * `MessageSizeCalculator` (bubble plan) and `MessageView`:
 *
 * - Messages from others sit at the inline start in the secondary bubble;
 *   your own at the inline end in the accent bubble.
 * - In chats that are not DMs, others' messages reserve an avatar column. The
 *   sender's name shows on the first message of a run, the avatar on the last
 *   (aligned to the bottom). Your own messages show neither.
 * - The bubble's tail shows on the last message of a run.
 * - A message that is only one to many emoji, with no reply or other content,
 *   has no bubble and renders the emoji large. Content can also ask for no
 *   bubble (stickers, PNG photos without a caption).
 *
 * Direction: the side a row sits on depends only on who sent it, read in the
 * interface direction (incoming at the inline start, outgoing at the inline
 * end). The message text's own direction never moves the row, the avatar,
 * the name or the bubble; it applies only to the text container inside the
 * bubble. Mac: `MessageView` places avatar and bubble by `outgoing` alone and
 * sets the writing direction on the text only.
 */

import type { DirAttribute, Direction } from "@inline/chat-ui"
import type { EmojiSize } from "./emoji"

export type RowLayoutInput = {
  readonly out: boolean
  readonly isDM: boolean
  readonly firstInGroup: boolean
  readonly lastInGroup: boolean
  readonly emoji: EmojiSize
  /** A reply line, media, blocks, a link preview or unsupported content. */
  readonly hasExtras: boolean
  /** The content asks for no bubble (stickers, PNG photos without a caption). */
  readonly noBubble?: boolean
  /** The message text's direction (`TextDocument.dir`), undefined when it has no letters. */
  readonly textDir?: Direction | undefined
  /**
   * The interface direction, when the caller wants rows to state it
   * themselves (see `MessageRowContext.interfaceDir`). Undefined: inherit.
   */
  readonly interfaceDir?: Direction | undefined
}

export type BubbleKind = "outgoing" | "incoming" | "none"

export type RowLayout = {
  readonly side: "start" | "end"
  readonly bubble: BubbleKind
  readonly showName: boolean
  readonly showAvatar: boolean
  /** Keep the avatar column's width even where the avatar is not drawn. */
  readonly reserveAvatar: boolean
  readonly tail: boolean
  /** The emoji size that applies (none when the message has a bubble). */
  readonly emoji: EmojiSize
  /** `dir` for the row element: the interface direction, or undefined to inherit it. Never the text's. */
  readonly rowDir: Direction | undefined
  /** `dir` for the text container inside the bubble, and only there. */
  readonly textDir: DirAttribute
}

export const rowLayout = (input: RowLayoutInput): RowLayout => {
  const others = !input.out && !input.isDM
  const emoji = input.hasExtras ? "none" : input.emoji
  const bubble: BubbleKind = emoji !== "none" || input.noBubble ? "none" : input.out ? "outgoing" : "incoming"
  return {
    side: input.out ? "end" : "start",
    bubble,
    showName: others && input.firstInGroup,
    showAvatar: others && input.lastInGroup,
    reserveAvatar: others,
    tail: bubble !== "none" && input.lastInGroup,
    emoji,
    rowDir: input.interfaceDir,
    textDir: input.textDir ?? "auto",
  }
}
