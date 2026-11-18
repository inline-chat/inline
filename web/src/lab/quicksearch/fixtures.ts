/**
 * Generated data for the Quick Search lab: people, direct chats, threads in
 * spaces, archived chats, messages and server-only people, in mixed scripts
 * (Latin with accents, Persian, Arabic, Hebrew, CJK, Cyrillic, emoji) and
 * with long titles. Deterministic: the same seed gives the same data.
 */

import type { ChatRow, DialogRow, Row, SpaceRow, UserRow } from "@inline/core-protocol"
import type { ChatID, DialogID, MessageID, SpaceID, UserID } from "@inline/ids"

export type LabMessage = {
  readonly chatId: ChatID
  readonly messageId: MessageID
  readonly chatTitle: string
  readonly text: string
  /** Seconds since the epoch. */
  readonly date: number
  readonly spaceId?: SpaceID
  readonly peerUserId?: UserID
}

export type LabData = {
  readonly me: UserRow
  readonly rows: readonly Row[]
  /** Open, non-archived dialogs in sidebar order. */
  readonly inbox: readonly DialogRow[]
  readonly archived: readonly DialogRow[]
  readonly spaces: readonly SpaceRow[]
  readonly messages: readonly LabMessage[]
  /** People only the server knows. */
  readonly remoteUsers: readonly UserRow[]
  readonly counts: { readonly chats: number; readonly people: number; readonly spaces: number; readonly messages: number }
}

/** Mulberry32: small, fast, deterministic. */
const random = (seed: number) => {
  let state = seed >>> 0
  return () => {
    state = (state + 0x6d2b79f5) >>> 0
    let t = state
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

const people: readonly [string, string?, string?][] = [
  ["Ada", "Lovelace", "ada"],
  ["Grace", "Hopper", "grace"],
  ["Alan", "Turing", "alan"],
  ["Margaret", "Hamilton", "margaret"],
  ["Linus", "Torvalds"],
  ["José", "Álvarez", "jose"],
  ["Zoë", "Ünal", "zoe"],
  ["Søren", "Kierkegaard"],
  ["François", "Dubois", "francois"],
  ["Mehmet", "Yılmaz"],
  ["علی", "رضایی", "ali"],
  ["مریم", "احمدی", "maryam"],
  ["سارا", "کریمی"],
  ["محمد", "حسینی", "mohammad"],
  ["فاطمه", "موسوی"],
  ["يوسف", "العلي"],
  ["ليلى", "حداد", "layla"],
  ["נועה", "כהן", "noa"],
  ["דוד", "לוי"],
  ["李", "伟", "liwei"],
  ["王", "芳"],
  ["佐藤", "健", "ken"],
  ["鈴木", "花子"],
  ["김", "민준", "minjun"],
  ["Иван", "Петров", "ivan"],
  ["Ольга", "Смирнова"],
  ["Priya", "Sharma", "priya"],
  ["Arjun", "Mehta"],
  ["Chidi", "Okafor", "chidi"],
  ["Amara", "Nwosu"],
  ["Lucía", "Fernández"],
  ["Mateus", "Silva"],
  ["Ingrid", "Bergström"],
  ["Nguyễn", "Văn An", "an"],
  ["Thảo", "Trần"],
  ["Deploy", "Bot", "deploybot"],
  ["Review", "Agent", "reviewer"],
  ["Hannah", "Schmidt"],
  ["Kwame", "Mensah"],
  ["Elif", "Şahin"],
  ["Björn", "Ålund"],
  ["Ana", "Popescu"],
  ["Tomás", "Ó Briain"],
  ["Yara", "Haddad"],
  ["Reza", "Tehrani", "reza"],
  ["Niloufar", "Bahrami"],
  ["Sina", "Moradi"],
  ["Parisa", "Jafari"],
]

const remotePeople: readonly [string, string?, string?][] = [
  ["Katherine", "Johnson", "kjohnson"],
  ["Hedy", "Lamarr", "hedy"],
  ["Barbara", "Liskov", "liskov"],
  ["Donald", "Knuth", "knuth"],
  ["Frances", "Allen"],
  ["Edsger", "Dijkstra", "ewd"],
  ["Radia", "Perlman"],
  ["کاوه", "نوری", "kaveh"],
  ["شیرین", "صالحی"],
  ["Ада", "Ковальская"],
  ["田中", "太郎", "tanaka"],
  ["박", "지성"],
  ["Adele", "Goldberg"],
  ["Ken", "Thompson", "ken_t"],
  ["Dennis", "Ritchie", "dmr"],
]

const spaceNames = ["Platform", "Design", "مهندسی", "עיצוב", "営業チーム", "🚀 Launch", "Growth & Partnerships"]

const topicWords = [
  "Design review",
  "Deploy plans",
  "Incident",
  "Roadmap",
  "Onboarding",
  "Hiring",
  "Billing",
  "Search",
  "Release notes",
  "Performance",
  "Sync engine",
  "Web client",
  "iOS app",
  "macOS app",
  "Android",
  "Notifications",
  "Offline mode",
  "Analytics",
  "Pricing",
  "Customer feedback",
  "بازبینی طراحی",
  "برنامه انتشار",
  "جلسه هفتگی",
  "پشتیبانی مشتری",
  "مراجعة التصميم",
  "خطة الإطلاق",
  "סקירת עיצוב",
  "תכנון רבעוני",
  "設計レビュー",
  "リリース計画",
  "设计评审",
  "发布计划",
  "디자인 리뷰",
  "Планирование релиза",
  "Ревью дизайна",
]

const qualifiers = ["Q3", "Q4", "2026", "v2", "follow-up", "kickoff", "sync", "retro", "draft", "weekly", "urgent", "notes"]

const emojis = ["🚀", "🎨", "🐛", "📈", "🔥", "🧪", "📦", "🛠", "💬", "🌍"]

const longTitles = [
  "Quarterly planning for the infrastructure migration and the observability rollout across every region",
  "A very long thread title that keeps going so it has to be truncated with an ellipsis at the end of the row",
  "برنامه‌ریزی فصلی برای مهاجرت زیرساخت و راه‌اندازی سامانه پایش در همه مناطق و همه تیم‌ها",
  "תכנון רבעוני להעברת התשתית ולהשקת מערכת הניטור בכל האזורים ובכל הצוותים בחברה",
  "インフラ移行と監視システムの全リージョン展開に関する四半期計画と各チームの担当範囲の確認",
]

const messageWords = [
  "the",
  "deploy",
  "rollout",
  "is",
  "done",
  "review",
  "design",
  "please",
  "check",
  "latency",
  "search",
  "index",
  "migration",
  "tomorrow",
  "shipped",
  "regression",
  "fixed",
  "green",
  "build",
  "release",
  "customer",
  "feedback",
  "pricing",
  "draft",
  "meeting",
  "notes",
  "سلام",
  "انتشار",
  "طراحی",
  "بازبینی",
  "جلسه",
  "مشتری",
  "שלום",
  "שחרור",
  "עיצוב",
  "リリース",
  "設計",
  "发布",
  "设计",
  "релиз",
  "дизайн",
  "café",
  "naïve",
  "résumé",
  "🚀",
  "✅",
]

const pick = <T>(rand: () => number, list: readonly T[]): T => list[Math.floor(rand() * list.length)] as T

export const generateLabData = (options: { seed?: number; threads?: number; messages?: number; now?: number } = {}): LabData => {
  const rand = random(options.seed ?? 7)
  const now = Math.floor((options.now ?? Date.now()) / 1000)
  const rows: Row[] = []
  const me: UserRow = { kind: "user", id: "1" as UserID, firstName: "Mo", lastName: "Lab", username: "me" }
  rows.push(me)

  const spaces: SpaceRow[] = spaceNames.map((name, index) => ({ kind: "space", id: String(100 + index) as SpaceID, name }))
  rows.push(...spaces)

  const users: UserRow[] = people.map(([firstName, lastName, username], index) => ({
    kind: "user",
    id: String(1000 + index) as UserID,
    firstName,
    ...(lastName ? { lastName } : {}),
    ...(username ? { username } : {}),
    ...(username === "deploybot" || username === "reviewer" ? { bot: true } : {}),
  }))
  rows.push(...users)

  const dialogs: DialogRow[] = []
  const chats: ChatRow[] = []
  let nextChat = 5000
  const addChat = (chat: Omit<ChatRow, "kind" | "id">, dialog: Partial<DialogRow> = {}) => {
    const id = String(nextChat++) as ChatID
    const row: ChatRow = { kind: "chat", id, lastActivityDate: now - Math.floor(rand() * 400 * 86400), ...chat }
    chats.push(row)
    dialogs.push({
      kind: "dialog",
      id: String(id) as DialogID,
      chatId: id,
      pinned: false,
      archived: false,
      open: true,
      unreadCount: rand() < 0.15 ? 1 + Math.floor(rand() * 30) : 0,
      unreadMark: false,
      ...(chat.peerUserId !== undefined ? { peerUserId: chat.peerUserId } : {}),
      ...(chat.spaceId !== undefined ? { spaceId: chat.spaceId } : {}),
      ...dialog,
    })
    return row
  }

  // Direct chats with most people; the last few have none (found as people).
  for (const user of users.slice(0, users.length - 6)) addChat({ peerUserId: user.id })

  // Threads in spaces, with mixed scripts, emoji and some very long titles.
  const threadCount = options.threads ?? 260
  for (let index = 0; index < threadCount; index++) {
    const space = rand() < 0.85 ? pick(rand, spaces) : undefined
    const roll = rand()
    const title =
      index < longTitles.length
        ? (longTitles[index] as string)
        : roll < 0.6
          ? `${pick(rand, topicWords)} ${pick(rand, qualifiers)}`
          : roll < 0.8
            ? `${pick(rand, topicWords)}`
            : `${pick(rand, emojis)} ${pick(rand, topicWords)}`
    addChat({
      title,
      ...(rand() < 0.2 ? { emoji: pick(rand, emojis) } : {}),
      ...(space ? { spaceId: space.id } : {}),
    })
  }

  // Archive about one in eight threads; pin a few at the top.
  const archived: DialogRow[] = []
  const inbox: DialogRow[] = []
  dialogs.forEach((dialog, index) => {
    const isThread = dialog.peerUserId === undefined
    if (isThread && index % 8 === 3) archived.push({ ...dialog, archived: true })
    else inbox.push(index < 4 ? { ...dialog, pinned: true } : dialog)
  })
  rows.push(...chats, ...inbox, ...archived)

  // Messages: a few per chat, newest within the last year.
  const titleOf = new Map<ChatID, string>()
  for (const chat of chats) {
    const peer = chat.peerUserId !== undefined ? users.find((user) => user.id === chat.peerUserId) : undefined
    titleOf.set(chat.id, peer ? [peer.firstName, peer.lastName].filter(Boolean).join(" ") : (chat.title ?? "Chat"))
  }
  const messages: LabMessage[] = []
  const messageCount = options.messages ?? 3000
  for (let index = 0; index < messageCount; index++) {
    const chat = pick(rand, chats)
    const words: string[] = []
    const length = 4 + Math.floor(rand() * 26)
    for (let w = 0; w < length; w++) words.push(pick(rand, messageWords))
    messages.push({
      chatId: chat.id,
      messageId: String(10_000 + index) as MessageID,
      chatTitle: titleOf.get(chat.id) ?? "Chat",
      text: words.join(" "),
      date: now - Math.floor(rand() * 365 * 86400),
      ...(chat.spaceId !== undefined ? { spaceId: chat.spaceId } : {}),
      ...(chat.peerUserId !== undefined ? { peerUserId: chat.peerUserId } : {}),
    })
  }

  const remoteUsers: UserRow[] = remotePeople.map(([firstName, lastName, username], index) => ({
    kind: "user",
    id: String(9000 + index) as UserID,
    firstName,
    ...(lastName ? { lastName } : {}),
    ...(username ? { username } : {}),
  }))

  return {
    me,
    rows,
    inbox,
    archived,
    spaces,
    messages,
    remoteUsers,
    counts: { chats: chats.length, people: users.length, spaces: spaces.length, messages: messages.length },
  }
}
