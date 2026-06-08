export const threadTitleMdUrl = (input: { spaceId: bigint; title: string }): string => {
  const params = new URLSearchParams({
    space_id: input.spaceId.toString(),
    title: input.title,
  })
  return `inline://thread?${params.toString()}`
}

export const parseThreadTitleMdUrl = (rawUrl: string): { spaceId: bigint; title: string } | null => {
  let url: URL
  try {
    url = new URL(rawUrl)
  } catch {
    return null
  }

  if (url.protocol.toLowerCase() !== "inline:" || url.hostname.toLowerCase() !== "thread") {
    return null
  }

  if (url.searchParams.get("id") || url.searchParams.get("chat_id")) {
    return null
  }

  const rawSpaceId = url.searchParams.get("space_id")
  const title = url.searchParams.get("title")?.trim()
  if (!rawSpaceId || !/^\d+$/.test(rawSpaceId) || !title) {
    return null
  }

  const spaceId = BigInt(rawSpaceId)
  return spaceId > 0n ? { spaceId, title } : null
}
