export const threadTitleMdUrl = (input: { spaceId: bigint; title: string }): string => {
  const params = new URLSearchParams()
  if (input.spaceId > 0n) {
    params.set("space_id", input.spaceId.toString())
  }
  params.set("title", input.title)

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
  if (!title) {
    return null
  }

  if (!rawSpaceId) {
    return { spaceId: 0n, title }
  }

  if (!/^\d+$/.test(rawSpaceId)) {
    return null
  }

  const spaceId = BigInt(rawSpaceId)
  return { spaceId, title }
}
