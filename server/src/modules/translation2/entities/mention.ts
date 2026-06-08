export const mentionMdUrl = (userId: bigint): string => {
  return `inline://user/${userId.toString()}`
}

export const parseMentionMdUrl = (rawUrl: string): bigint | null => {
  let url: URL
  try {
    url = new URL(rawUrl)
  } catch {
    return null
  }

  if (url.protocol.toLowerCase() !== "inline:" || url.hostname.toLowerCase() !== "user") {
    return null
  }

  const id = url.searchParams.get("id") ?? url.searchParams.get("user_id") ?? url.pathname.replace(/^\/+/, "")
  if (!id || !/^\d+$/.test(id)) {
    return null
  }

  const userId = BigInt(id)
  return userId > 0n ? userId : null
}
