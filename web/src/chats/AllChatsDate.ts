const timeFormatter = new Intl.DateTimeFormat(undefined, {
  hour: "numeric",
  minute: "2-digit",
})
const weekdayTimeFormatter = new Intl.DateTimeFormat(undefined, {
  weekday: "short",
  hour: "numeric",
  minute: "2-digit",
})
const currentYearFormatter = new Intl.DateTimeFormat(undefined, {
  month: "short",
  day: "numeric",
})
const otherYearFormatter = new Intl.DateTimeFormat(undefined, {
  month: "short",
  day: "numeric",
  year: "numeric",
})

const startOfDay = (date: Date) =>
  new Date(date.getFullYear(), date.getMonth(), date.getDate())

const dayDifference = (date: Date, now: Date) =>
  Math.round((startOfDay(now).getTime() - startOfDay(date).getTime()) / 86_400_000)

export const allChatsSectionKey = (timestamp: number) => {
  const date = new Date(timestamp * 1_000)
  return `${date.getFullYear()}-${date.getMonth()}-${date.getDate()}`
}
export const allChatsSectionTitle = (timestamp: number, now = new Date()) => {
  const date = new Date(timestamp * 1_000)
  const days = dayDifference(date, now)
  if (days === 0) return "Today"
  if (days === 1) return "Yesterday"
  return date.getFullYear() === now.getFullYear()
    ? currentYearFormatter.format(date)
    : otherYearFormatter.format(date)
}

export const allChatsRowTime = (timestamp: number, now = new Date()) => {
  if (timestamp <= 0) return undefined
  const date = new Date(timestamp * 1_000)
  if (now.getTime() - date.getTime() < 60_000) return "just now"

  const days = dayDifference(date, now)
  if (days === 0) return timeFormatter.format(date)
  if (days > 0 && days < 7) return weekdayTimeFormatter.format(date)
  return undefined
}
