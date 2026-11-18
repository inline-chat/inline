/**
 * Generated chats for the sidebar lab: seeded, so a count always produces the
 * same account. Mixed scripts (Latin, Arabic, Hebrew, Persian, CJK, Korean,
 * Cyrillic, Greek, Devanagari), long titles, emoji, DMs and threads, a few
 * photos as data URLs (no network), unread counts, marks, pins and drafts.
 */

import type { ChatRow, DialogRow, DraftRow, MessageRow, UserRow } from "@inline/core-protocol"
import { receivedMessageRowId } from "@inline/core-protocol"
import type { ChatID, DialogID, MessageID, UserID } from "@inline/ids"

export type LabChat = {
  readonly n: number
  dialog: DialogRow
  chat: ChatRow
  last?: MessageRow
  draft?: DraftRow
}

export type LabAccount = {
  readonly users: UserRow[]
  readonly chats: LabChat[]
}

/** mulberry32: small, fast, seeded. */
export const random = (seed: number) => {
  let state = seed >>> 0
  return () => {
    state = (state + 0x6d2b79f5) >>> 0
    let t = state
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

const pick = <T,>(next: () => number, values: readonly T[]): T => values[Math.floor(next() * values.length)]!

const people: readonly (readonly [string, string | undefined])[] = [
  ["Ada", "Lovelace"],
  ["Grace", "Hopper"],
  ["Alan", "Turing"],
  ["Margaret", "Hamilton"],
  ["Katherine", "Johnson"],
  ["Linus", undefined],
  ["Émile", "Zola"],
  ["Søren", "Kierkegaard"],
  ["ليلى", "حسن"],
  ["عمر", "خالد"],
  ["نور", "الهدى"],
  ["נועה", "כהן"],
  ["דוד", "לוי"],
  ["آرش", "کمانگیر"],
  ["سارا", "نیک‌نام"],
  ["王", "芳"],
  ["佐藤", "健"],
  ["김", "민준"],
  ["Анна", "Иванова"],
  ["Дмитрий", "Соколов"],
  ["Ελένη", "Παπαδοπούλου"],
  ["प्रिया", "शर्मा"],
  ["Sam", "🚀"],
  ["Maximiliana-Josefina", "von Habsburg-Lothringen-Esterházy"],
  ["Kai", undefined],
  ["Zoë", "Ng"],
]

const threadTitles: readonly string[] = [
  "Launch plan",
  "Design review",
  "Design review: Q4 roadmap, everything that slipped from Q3, and the things we promised in the all-hands",
  "Brand refresh",
  "Releases",
  "Incidents",
  "مناقشة الميزانية",
  "תכנון ספרינט",
  "バグ報告",
  "디자인 시스템",
  "Обсуждение релиза",
  "Αρχιτεκτονική",
  "स्प्रिंट योजना",
  "Hiring loop — backend",
  "Customer feedback 🗣️",
  "",
  "Random",
  "Offsite logistics ✈️",
]

const emojis: readonly string[] = ["🚀", "🎨", "📦", "🧪", "🛠️", "📣", "🐛", "☕️", "🗂️", "🌍", "👩🏽‍💻", "🇯🇵"]

const messages: readonly string[] = [
  "Sounds good, shipping it tomorrow",
  "Can you take a look at the latest build?",
  "👍",
  "I left a few comments on the doc. Mostly small things, but the second section needs a rewrite before we send it out to the wider group.",
  "سأرسل التفاصيل بعد الاجتماع",
  "אני בדרך",
  "明日の会議は10時からです",
  "Спасибо!",
  "Merged 🎉",
  "line one\nline two\n\nline four",
  "https://inline.chat/c/123 has the context",
  "ok",
]

const drafts: readonly string[] = ["half a thought", "Let me check with", "یادم باشد فردا", "TODO: reply"]

/** A tiny inline SVG portrait: a data URL, so the lab never touches the network. */
const photo = (hue: number): string =>
  `data:image/svg+xml,${encodeURIComponent(
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 40 40"><rect width="40" height="40" fill="hsl(${hue} 60% 55%)"/><circle cx="20" cy="16" r="7" fill="hsl(${hue} 40% 92%)"/><path d="M6 40c2-9 8-13 14-13s12 4 14 13z" fill="hsl(${hue} 40% 92%)"/></svg>`,
  )}`

export const chatIdOf = (n: number) => String(n) as ChatID
export const userIdOf = (n: number) => String(1000 + n) as UserID
const dialogIdOf = (n: number) => String(n) as DialogID

/** The last activity of chat `n` in a fresh account: newest first. */
const BASE_DATE = 1_790_000_000

export const messageRow = (chat: number, id: number, text: string, out: boolean, date: number, from: UserID): MessageRow => ({
  kind: "message",
  id: receivedMessageRowId(chatIdOf(chat), String(id) as MessageID),
  chatId: chatIdOf(chat),
  messageId: String(id) as MessageID,
  fromId: from,
  out,
  date,
  text,
  state: "sent",
})

export const ME = "1" as UserID

export const generateAccount = (count: number, seed = 7): LabAccount => {
  const next = random(seed)
  const userCount = Math.max(1, Math.min(400, Math.ceil(count / 3)))
  const users: UserRow[] = []
  for (let u = 1; u <= userCount; u++) {
    const [first, last] = people[(u - 1) % people.length]!
    const round = Math.floor((u - 1) / people.length)
    users.push({
      kind: "user",
      id: userIdOf(u),
      firstName: round === 0 ? first : `${first} ${round + 1}`,
      ...(last ? { lastName: last } : {}),
      ...(u % 19 === 4 ? { photoUrl: photo((u * 47) % 360) } : {}),
    })
  }
  const chats: LabChat[] = []
  for (let n = 1; n <= count; n++) {
    const direct = next() < 0.4
    const userNumber = 1 + Math.floor(next() * userCount)
    const peer = users[userNumber - 1]!
    const date = BASE_DATE - n * 97
    const titleIndex = Math.floor(next() * threadTitles.length)
    const title = threadTitles[titleIndex]!
    const chat: ChatRow = direct
      ? { kind: "chat", id: chatIdOf(n), peerUserId: peer.id, lastActivityDate: date }
      : {
          kind: "chat",
          id: chatIdOf(n),
          ...(title ? { title: n > threadTitles.length ? `${title} ${n}`.trim() : title } : {}),
          ...(next() < 0.45 ? { emoji: pick(next, emojis) } : {}),
          lastActivityDate: date,
        }
    const unreadRoll = next()
    const dialog: DialogRow = {
      kind: "dialog",
      id: dialogIdOf(n),
      chatId: chatIdOf(n),
      ...(direct ? { peerUserId: peer.id } : {}),
      pinned: n <= 3,
      archived: false,
      open: n <= 3 || next() < 0.8,
      unreadCount: unreadRoll < 0.18 ? 1 + Math.floor(next() * (next() < 0.1 ? 240 : 9)) : 0,
      unreadMark: unreadRoll >= 0.18 && unreadRoll < 0.22,
    }
    const messageId = n * 1000
    const out = next() < 0.3
    const last = messageRow(n, messageId, pick(next, messages), out, date, out ? ME : peer.id)
    const withLast: ChatRow = { ...chat, lastMessageId: last.messageId! }
    const draft: DraftRow | undefined =
      next() < 0.05 ? { kind: "draft", id: chatIdOf(n), text: pick(next, drafts), revision: 1 } : undefined
    chats.push({ n, dialog, chat: withLast, last, ...(draft ? { draft } : {}) })
  }
  return { users, chats }
}

export const LONG_TITLE =
  "A very long thread title that keeps going past the edge of any reasonable sidebar width — and then some more"
export const nextMessages = messages
