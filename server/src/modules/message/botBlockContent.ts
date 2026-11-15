import { BlockContent, type Block } from "@inline-chat/protocol/core"
import { blockChildren, validateBlockContent, validateTopLevelSpanOrder } from "@in/server/modules/message/blockContent"
import { annotateBlockContentDirections } from "@in/server/modules/message/blockDirection"
import { RealtimeRpcError } from "@in/server/realtime/errors"

function hasImages(blocks: readonly Block[]): boolean {
  return blocks.some((block) => {
    switch (block.kind.oneofKind) {
      case "image":
      case "album":
        return true
      case "widget":
        return block.kind.widget.images.length > 0
      default:
        return hasImages(blockChildren(block))
    }
  })
}

/**
 * Structured content a bot sends with its flat text. Unlike the server's own
 * Markdown projection, an invalid tree is rejected rather than dropped, so the
 * bot learns about it. Images go through attachments or Markdown, not here.
 * Top-level blocks must cover the text in order; see `validateTopLevelSpanOrder`.
 */
export function validateBotBlockContent(text: string | undefined, content: BlockContent): BlockContent {
  if (!text || content.blocks.length === 0 || hasImages(content.blocks)) throw RealtimeRpcError.BadRequest()
  const copy = BlockContent.clone(content)
  try {
    // Direction is server-computed, as for parsed Markdown, replacing any sent.
    annotateBlockContentDirections(text, copy)
    validateBlockContent(text, copy, "native")
    validateTopLevelSpanOrder(copy)
  } catch {
    throw RealtimeRpcError.BadRequest()
  }
  return copy
}
