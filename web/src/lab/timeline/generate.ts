/**
 * Seeded history for the timeline lab. Pure and deterministic: the same seed
 * gives the same messages, text and media boxes. Tested in `generate.test.ts`.
 */

import { receivedMessageRowId, type MessageRow } from "@inline/core-protocol"
import { chatId, messageId, userId, type ChatID, type UserID } from "@inline/ids"

export const LAB_CHAT: ChatID = chatId(4242)
export const LAB_VIEWER: UserID = userId(1)
export const LAB_SENDERS: readonly UserID[] = [LAB_VIEWER, userId(2), userId(3), userId(4)]

/** 2026-11-01 09:00 UTC, in seconds: the first message. */
const START = Date.UTC(2026, 10, 1, 9, 0, 0) / 1000

/** Mulberry32: small, fast, good enough for test data. Returns floats in [0, 1). */
export const createRandom = (seed: number) => {
  let state = seed >>> 0
  const next = () => {
    state = (state + 0x6d2b79f5) >>> 0
    let t = state
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
  return {
    next,
    /** Integer in [min, max]. */
    int: (min: number, max: number) => min + Math.floor(next() * (max - min + 1)),
    pick: <T>(list: readonly T[]): T => list[Math.floor(next() * list.length)]!,
    chance: (p: number) => next() < p,
  }
}

export type Random = ReturnType<typeof createRandom>

const WORDS = (
  "the a to and of we it is for on that this with be can will should ship build review release timeline " +
  "message anchor scroll window prepend latest unread thread reply draft composer sidebar server client " +
  "migration deploy staging tomorrow today morning after lunch quickly carefully maybe definitely agreed " +
  "measurement drift pixel frame layout render budget performance keyboard focus selection sync offline " +
  "internationalization configuration responsibilities straightforward"
).split(" ")

/** A few right-to-left and mixed-script lines, so rows exercise `dir="auto"` and bidi wrapping. */
const OTHER_SCRIPTS = [
  "مرحبا، هل راجعت التغييرات في الجدول الزمني؟",
  "שלום, אני אבדוק את זה אחרי הפגישה",
  "Ок, посмотрю после обеда и напишу",
  "了解しました。明日までに確認します。",
]

/** Text of a random length: mostly short, some paragraphs, a few long ones. */
export const randomText = (random: Random): string => {
  if (random.chance(0.05)) return random.pick(OTHER_SCRIPTS)
  const roll = random.next()
  const count = roll < 0.6 ? random.int(2, 15) : roll < 0.9 ? random.int(15, 60) : random.int(60, 200)
  const words: string[] = []
  for (let i = 0; i < count; i++) words.push(random.pick(WORDS))
  const first = words[0] ?? "ok"
  words[0] = first.charAt(0).toUpperCase() + first.slice(1)
  return `${words.join(" ")}.`
}

/** A media box in a message. `late` boxes have no reserved size until the lab resolves them. */
export type LabMedia = { height: number; late: boolean }

export type LabMessage = { row: MessageRow; media?: LabMedia }

export const labMessage = (n: number, fromId: UserID, date: number, text: string): MessageRow => ({
  kind: "message",
  id: receivedMessageRowId(LAB_CHAT, messageId(n)),
  chatId: LAB_CHAT,
  messageId: messageId(n),
  fromId,
  out: fromId === LAB_VIEWER,
  date,
  text,
  state: "sent",
})

/**
 * `count` messages with IDs 1..count, oldest first. Senders repeat often
 * enough to form groups; gaps are mostly short, sometimes longer than the
 * 300 s grouping limit, and now and then cross a day.
 */
export const generateHistory = (seed: number, count: number): LabMessage[] => {
  const random = createRandom(seed)
  const messages: LabMessage[] = []
  let date = START
  let sender = LAB_SENDERS[1]!
  for (let n = 1; n <= count; n++) {
    if (!random.chance(0.55)) sender = random.pick(LAB_SENDERS)
    const gap = random.chance(0.02) ? random.int(6, 20) * 3600 : random.chance(0.25) ? random.int(301, 1800) : random.int(5, 240)
    date += gap
    const row = labMessage(n, sender, date, randomText(random))
    const media: LabMedia | undefined = random.chance(0.12)
      ? { height: random.int(80, 260) + random.pick([0, 0.25, 0.5, 0.75]), late: random.chance(0.5) }
      : undefined
    messages.push(media ? { row, media } : { row })
  }
  return messages
}
