import { MessageEntity_Type, type MessageEntities } from "@inline-chat/protocol/core"

export type SplitReplyQuote = {
  quote: string
  caption: string
  entities: MessageEntities | undefined
}

const isWhitespace = (char: string) => /\s/.test(char)

/**
 * A reply whose text opens with a quote, as composer "> " lines make it, from a client that
 * doesn't send `reply_quote` yet. Like Telegram, the quote moves out of the text so the
 * message, its notification and its chat preview are only the caption. Undefined when the
 * text doesn't open with a quote or has no caption after it. Offsets are UTF-16, as in JS.
 */
export function splitLeadingReplyQuote(
  text: string | undefined,
  entities: MessageEntities | undefined,
): SplitReplyQuote | undefined {
  if (!text || !entities) return undefined
  const quoteEntity = entities.entities.find(
    (entity) => entity.type === MessageEntity_Type.BLOCKQUOTE && entity.offset === 0n,
  )
  if (!quoteEntity || quoteEntity.length <= 0n || quoteEntity.length > BigInt(text.length)) return undefined

  const quoteEnd = Number(quoteEntity.length)
  const quote = text.slice(0, quoteEnd).trim()
  let captionStart = quoteEnd
  while (captionStart < text.length && isWhitespace(text[captionStart]!)) captionStart += 1
  const caption = text.slice(captionStart)
  if (!quote || !caption.trim()) return undefined

  // Styles inside the quote stay with it in the source message; the caption keeps its own.
  const shift = BigInt(captionStart)
  const captionEntities = entities.entities
    .filter((entity) => entity.offset >= shift)
    .map((entity) => ({ ...entity, offset: entity.offset - shift }))
  return {
    quote,
    caption,
    entities: captionEntities.length > 0 ? { entities: captionEntities } : undefined,
  }
}
