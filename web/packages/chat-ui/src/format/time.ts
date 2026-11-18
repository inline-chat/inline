/**
 * Message times and day separators, with the locale, time zone and clock
 * injected so they are deterministic in tests and on public pages rendered on
 * the server.
 *
 * Matches the Mac app:
 * - Message time: the locale's hour and minutes (`jmm` template), 12 or 24
 *   hour as the locale prefers (`MessageTimeAndState.formatter`).
 * - Tooltip: medium date and short time.
 * - Day separator: "Today", "Yesterday", otherwise the abbreviated date with
 *   year, "Nov 17, 2026" in English (`MessageListAppKit` date separator,
 *   `DateBadge`).
 */

export type TimeFormatOptions = {
  /** BCP 47 locale, for example "en-US". Undefined uses the runtime default. */
  readonly locale?: string | readonly string[]
  /** IANA time zone, for example "Europe/Berlin". Undefined uses the runtime default. */
  readonly timeZone?: string
  /** Milliseconds since the epoch. Default `Date.now`. */
  readonly now?: () => number
  /** Force a 12 or 24 hour clock; undefined follows the locale. */
  readonly hour12?: boolean
}

export type DayLabelKind = "today" | "yesterday" | "date"

export type DayLabel = {
  readonly kind: DayLabelKind
  readonly text: string
}

export type TimeFormatter = {
  /** "3:07 PM" or "15:07". `seconds` is seconds since the epoch, as message rows carry. */
  readonly time: (seconds: number) => string
  /** "Nov 17, 2026, 3:07 PM". */
  readonly tooltip: (seconds: number) => string
  /** The day separator label for a message date. */
  readonly dayLabel: (seconds: number) => DayLabel
  /**
   * The calendar day of a date in the formatter's time zone, as days since
   * 1970-01-01. Two messages are on the same day when these are equal.
   */
  readonly dayNumber: (seconds: number) => number
}

const msPerDay = 86_400_000

const safeFormat = (create: () => Intl.DateTimeFormat, fallback: () => Intl.DateTimeFormat): Intl.DateTimeFormat => {
  try {
    return create()
  } catch {
    return fallback()
  }
}

/**
 * A formatter bound to one locale, time zone and clock. Create one per
 * settings change and reuse it; `Intl.DateTimeFormat` construction is the
 * expensive part. An invalid locale or time zone falls back to the runtime
 * default instead of throwing.
 */
export const createTimeFormatter = (options: TimeFormatOptions = {}): TimeFormatter => {
  const locales = options.locale as string | string[] | undefined
  const zone = options.timeZone
  const now = options.now ?? Date.now
  const hourCycle = options.hour12 === undefined ? {} : { hour12: options.hour12 }

  const make = (format: Intl.DateTimeFormatOptions): Intl.DateTimeFormat =>
    safeFormat(
      () => new Intl.DateTimeFormat(locales, { ...format, timeZone: zone }),
      () => new Intl.DateTimeFormat(undefined, format),
    )

  const timeFormat = make({ hour: "numeric", minute: "2-digit", ...hourCycle })
  const tooltipFormat = make({ dateStyle: "medium", timeStyle: "short", ...hourCycle })
  const dateFormat = make({ year: "numeric", month: "short", day: "numeric" })
  // Calendar arithmetic always in the Gregorian calendar with Latin digits.
  const dayParts = safeFormat(
    () => new Intl.DateTimeFormat("en-US-u-ca-gregory-nu-latn", { timeZone: zone, year: "numeric", month: "numeric", day: "numeric" }),
    () => new Intl.DateTimeFormat("en-US-u-ca-gregory-nu-latn", { year: "numeric", month: "numeric", day: "numeric" }),
  )

  const toDate = (seconds: number): Date => new Date(Number.isFinite(seconds) ? seconds * 1000 : 0)

  const dayNumberOfMs = (ms: number): number => {
    let year = 1970
    let month = 1
    let day = 1
    for (const part of dayParts.formatToParts(new Date(ms))) {
      if (part.type === "year") year = Number(part.value)
      else if (part.type === "month") month = Number(part.value)
      else if (part.type === "day") day = Number(part.value)
    }
    return Math.round(Date.UTC(year, month - 1, day) / msPerDay)
  }

  const dayNumber = (seconds: number): number => dayNumberOfMs(toDate(seconds).getTime())

  return {
    time: (seconds) => timeFormat.format(toDate(seconds)),
    tooltip: (seconds) => tooltipFormat.format(toDate(seconds)),
    dayNumber,
    dayLabel: (seconds) => {
      const today = dayNumberOfMs(now())
      const day = dayNumber(seconds)
      if (day === today) return { kind: "today", text: "Today" }
      if (day === today - 1) return { kind: "yesterday", text: "Yesterday" }
      return { kind: "date", text: dateFormat.format(toDate(seconds)) }
    },
  }
}
