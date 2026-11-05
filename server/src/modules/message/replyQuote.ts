import { MessageEntity_Type, type MessageEntities } from "@inline-chat/protocol/core"

/**
 * Puts a `reply_quote` sent apart from the text back at the start of the text as a
 * blockquote, the one way quotes are stored. Only builds that briefly split the quote out
 * send it. Offsets are UTF-16, as in JS.
 */
export function prependReplyQuote(
  quote: string,
  text: string | undefined,
  entities: MessageEntities | undefined,
): { text: string; entities: MessageEntities } {
  const quoted = quote.trim()
  const shift = BigInt(text ? quoted.length + 1 : 0)
  return {
    text: text ? `${quoted}\n${text}` : quoted,
    entities: {
      entities: [
        { type: MessageEntity_Type.BLOCKQUOTE, offset: 0n, length: BigInt(quoted.length), entity: { oneofKind: undefined } },
        ...(entities?.entities ?? []).map((entity) => ({ ...entity, offset: entity.offset + shift })),
      ],
    },
  }
}
