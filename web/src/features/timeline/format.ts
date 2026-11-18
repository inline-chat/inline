/**
 * Strings for the timeline's chrome. Pure; tested in `format.test.ts`.
 */

/**
 * The count on "jump to latest", as the Mac app prints it
 * (`ChatUnreadBadgeCount.format`): exact below 1,000, one decimal of
 * thousands below 10,000 ("1.2K", "3K"), whole thousands above ("12K").
 */
export const formatLatestCount = (count: number): string => {
  const value = Math.max(0, Math.floor(count))
  if (value < 1_000) return String(value)
  if (value < 10_000) {
    const tenths = Math.floor(value / 100)
    return tenths % 10 === 0 ? `${tenths / 10}K` : `${Math.floor(tenths / 10)}.${tenths % 10}K`
  }
  return `${Math.floor(value / 1_000)}K`
}

/** The accessible name of the "jump to latest" button; it carries the count the badge shows. */
export const latestButtonLabel = (count: number): string => {
  const value = Math.max(0, Math.floor(count))
  if (value === 0) return "Jump to latest"
  if (value === 1) return "Jump to latest, 1 new message"
  return `Jump to latest, ${formatLatestCount(value)} new messages`
}
