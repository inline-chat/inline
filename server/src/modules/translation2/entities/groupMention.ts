const maxInt64 = 9_223_372_036_854_775_807n

/** Group identity is distinct from user/Agent identity. Keep this vocabulary
 * exact: no implicit name lookup, query aliases, or cross-kind fallback. */
export const groupMentionMdUrl = (groupId: bigint): string | null =>
  groupId > 0n && groupId <= maxInt64 ? `inline://group/${groupId}` : null

export const parseGroupMentionMdUrl = (url: string): bigint | null => {
  const match = /^inline:\/\/group\/([1-9][0-9]{0,18})$/i.exec(url)
  if (!match || match[0].length !== url.length) return null
  const id = BigInt(match[1]!)
  return id <= maxInt64 ? id : null
}
