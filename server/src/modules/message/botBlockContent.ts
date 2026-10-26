import { BlockContent, type Block } from "@inline-chat/protocol/core"
import { validateBlockContent } from "@in/server/modules/message/blockContent"
import { annotateBlockContentDirections } from "@in/server/modules/message/blockDirection"
import { RealtimeRpcError } from "@in/server/realtime/errors"

function hasImages(blocks: readonly Block[]): boolean {
  return blocks.some((block) => {
    switch (block.kind.oneofKind) {
      case "image":
      case "album":
        return true
      case "disclosure":
        return hasImages(block.kind.disclosure.children)
      case "quote":
        return hasImages(block.kind.quote.children)
      case "callout":
        return hasImages(block.kind.callout.children)
      case "list":
        return block.kind.list.items.some((item) => hasImages(item.children))
      default:
        return false
    }
  })
}

/**
 * Structured content a bot sends with its flat text. Unlike the server's own
 * Markdown projection, an invalid tree is rejected rather than dropped, so the
 * bot learns about it. Images go through attachments or Markdown, not here.
 */
export function validateBotBlockContent(text: string | undefined, content: BlockContent): BlockContent {
  if (!text || content.blocks.length === 0 || hasImages(content.blocks)) throw RealtimeRpcError.BadRequest()
  const copy = BlockContent.clone(content)
  try {
    // Direction is server-computed, as for parsed Markdown, replacing any sent.
    annotateBlockContentDirections(text, copy)
    validateBlockContent(text, copy, "native")
  } catch {
    throw RealtimeRpcError.BadRequest()
  }
  return copy
}
