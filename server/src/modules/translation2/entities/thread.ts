export const threadMdUrl = (chatId: bigint): string => {
  return `inline://thread?id=${encodeURIComponent(chatId.toString())}`
}

const maxInt64 = 9_223_372_036_854_775_807n

export const parseThreadMdUrl = (rawUrl: string): bigint | null => {
  let url: URL
  try {
    url = new URL(rawUrl)
  } catch {
    return null
  }

  if (url.protocol.toLowerCase() !== "inline:") {
    return null
  }

  const host = url.hostname.toLowerCase()
  if (host !== "thread" && host !== "chat") {
    return null
  }

  const id = url.searchParams.get("id") ?? url.searchParams.get("chat_id") ?? url.pathname.replace(/^\/+/, "")
  if (!id || !/^\d+$/.test(id)) {
    return null
  }

  const chatId = BigInt(id)
  return chatId > 0n && chatId <= maxInt64 ? chatId : null
}
