export type InlineMessageRef = {
  chatId: bigint
  messageId: bigint
}

// Legacy message ID format from MCP v1. Not used by the current tool contract,
// but kept as a utility for compatibility at call sites outside this package.
// Example: inline:chat:123:msg:456
export function formatInlineMessageId(ref: InlineMessageRef): string {
  return `inline:chat:${ref.chatId.toString()}:msg:${ref.messageId.toString()}`
}

export function parseInlineMessageId(id: string): InlineMessageRef {
  const parts = id.split(":")
  if (parts.length !== 5) throw new Error("invalid id")
  const [scheme, kind1, chatIdStr, kind2, msgIdStr] = parts
  if (scheme !== "inline") throw new Error("invalid id")
  if (kind1 !== "chat") throw new Error("invalid id")
  if (kind2 !== "msg") throw new Error("invalid id")

  // BigInt throws on invalid input, which is fine here.
  const chatId = BigInt(chatIdStr)
  const messageId = BigInt(msgIdStr)
  if (chatId <= 0n || messageId <= 0n) throw new Error("invalid id")
  return { chatId, messageId }
}
