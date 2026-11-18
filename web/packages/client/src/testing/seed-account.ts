import {
  MessageEntity_Type,
  Photo_Format,
  type Chat,
  type Dialog,
  type Message,
  type MessageEntity,
  type MessageMedia,
  type Space,
  type User,
} from "@inline-chat/protocol/core"
import { chatId as makeChatId, spaceId as makeSpaceId, userId as makeUserId } from "@inline/ids"
import { Db } from "../database"
import { DbObjectKind, type DbModel, type Dialog as DbDialog } from "../database/models"
import { DbQueryPlanType } from "../database/types"
import type { InlinePersistenceOperation, InlinePersistenceStore } from "../database/persistence"
import { syncBucketId } from "../realtime/sync/sync-types"
import {
  messageModel,
  upsertChat,
  upsertDialog,
  upsertSpace,
  upsertUser,
} from "../realtime/transactions/mappers"
import { SeededRandom } from "./rng"
import { chatPeer, type ServerModel } from "./server-model"

/**
 * A deterministic, realistic account for performance and end-to-end work.
 *
 * `generateSeedAccount` streams records (users, spaces, chats with their
 * dialog, then each chat's messages, oldest first) from a seed. It holds one
 * plan entry per chat and nothing per message, so memory stays flat at any
 * scale; consumers write records as they come.
 *
 * What it produces:
 * - message counts per chat follow a long tail (a few busy chats, many quiet);
 * - short (one line), medium and long (multi-paragraph) messages;
 * - Latin, Arabic, Hebrew, CJK and Cyrillic text, mixed scripts and emoji;
 * - entities (bold, mentions, URLs) whose ranges index the text (UTF-16);
 * - replies, and reply-thread chats whose parent is a message in another chat;
 * - photo metadata (sizes, no bytes) on a share of messages;
 * - outgoing messages, and a read boundary with an exact unread count.
 *
 * Sinks: `seedServerModel` (the server model) and `writeSeedAccountToStore`
 * (rows straight into a persistence store, in bounded batches).
 */

export type SeedAccountOptions = {
  seed: number
  chats: number
  /** Total messages across all chats. */
  messages: number
  users?: number
  spaces?: number
  selfUserId?: bigint
  /** Share of chats that are reply threads of a message elsewhere. */
  threadShare?: number
  /** Date of the oldest message, in seconds. */
  startDateSeconds?: number
}

/** Reference scales. `large` is the "honest" performance data set. */
export const SEED_ACCOUNT_SCALES = {
  small: { chats: 20, messages: 2_000 },
  medium: { chats: 500, messages: 50_000 },
  large: { chats: 3_000, messages: 300_000 },
} as const satisfies Record<string, Pick<SeedAccountOptions, "chats" | "messages">>

export type SeedRecord =
  | { kind: "user"; user: User }
  | { kind: "space"; space: Space }
  | { kind: "chat"; chat: Chat; dialog: Dialog; messageCount: number; participants: bigint[] }
  | { kind: "message"; message: Message }

type ChatPlan = {
  id: bigint
  messageCount: number
  spaceId?: bigint
  parent?: { chatId: bigint; messageId: bigint }
  readMaxId: bigint
  unreadCount: number
  firstDate: number
  participants: bigint[]
  script: Script
}

type Script = "latin" | "arabic" | "hebrew" | "cjk" | "cyrillic" | "mixed"

const vocabulary: Record<Exclude<Script, "mixed">, readonly string[]> = {
  latin: [
    "the", "review", "ship", "deploy", "thread", "draft", "later", "agreed", "build", "release",
    "migration", "latency", "customer", "design", "naïve", "café", "Straße", "proof", "today", "notes",
  ],
  arabic: ["مرحبا", "مراجعة", "تم", "الإصدار", "غدا", "التصميم", "العميل", "نعم", "ملاحظات", "الآن"],
  hebrew: ["שלום", "בדיקה", "מחר", "גרסה", "עיצוב", "לקוח", "כן", "הערות", "עכשיו", "תודה"],
  cjk: ["完成", "确认", "レビュー", "リリース", "设计", "客户", "明日", "メモ", "了解", "部署"],
  cyrillic: ["привет", "релиз", "дизайн", "клиент", "завтра", "заметки", "готово", "проверка"],
}

const emoji = ["😀", "🚀", "👍", "🎉", "👀", "🔥", "✅", "🙏"]

const scriptWeights: Record<Script, number> = {
  latin: 55,
  arabic: 10,
  hebrew: 10,
  cjk: 10,
  cyrillic: 5,
  mixed: 10,
}

const DEFAULT_START = 1_735_689_600 // 2025-01-01

const pickWord = (random: SeededRandom, script: Script) => {
  if (script === "mixed") {
    if (random.bool(0.1)) return random.pick(emoji)
    const scripts = ["latin", "arabic", "hebrew", "cjk", "cyrillic"] as const
    return random.pick(vocabulary[random.pick(scripts)])
  }
  return random.bool(0.04) ? random.pick(emoji) : random.pick(vocabulary[script])
}

const sentence = (random: SeededRandom, script: Script, words: number) =>
  Array.from({ length: words }, () => pickWord(random, script)).join(" ")

const messageText = (random: SeededRandom, script: Script) => {
  const roll = random.next()
  if (roll < 0.6) return sentence(random, script, random.int(1, 12))
  if (roll < 0.9) return sentence(random, script, random.int(20, 60))
  return Array.from({ length: random.int(3, 8) }, () =>
    sentence(random, script, random.int(30, 150)),
  ).join("\n\n")
}

/** Long-tail weights: chat i gets roughly 1 / (i + 1)^0.9 of the messages. */
const distribute = (total: number, chats: number) => {
  const weights = Array.from({ length: chats }, (_, index) => 1 / Math.pow(index + 1, 0.9))
  const sum = weights.reduce((acc, weight) => acc + weight, 0)
  const counts = weights.map((weight) => Math.floor((total * weight) / sum))
  const assigned = counts.reduce((acc, count) => acc + count, 0)
  counts[0] = (counts[0] ?? 0) + (total - assigned)
  return counts
}

const resolved = (options: SeedAccountOptions) => ({
  seed: options.seed,
  chats: options.chats,
  messages: options.messages,
  users: options.users ?? Math.max(4, Math.min(300, Math.ceil(options.chats / 2))),
  spaces: options.spaces ?? Math.max(1, Math.ceil(options.chats / 250)),
  selfUserId: options.selfUserId ?? 1n,
  threadShare: options.threadShare ?? 0.15,
  startDateSeconds: options.startDateSeconds ?? DEFAULT_START,
})

const FIRST_USER = 2n
const FIRST_SPACE = 100n
const FIRST_CHAT = 1_000n

/** Authors are drawn from their own stream so a pre-pass can count unread. */
const authorStream = (seed: number, chatId: bigint) =>
  new SeededRandom(seed).fork(`authors:${chatId}`)

const authorOf = (random: SeededRandom, plan: ChatPlan, selfUserId: bigint) =>
  random.bool(0.2) ? selfUserId : random.pick(plan.participants.filter((id) => id !== selfUserId))

const planChats = (options: ReturnType<typeof resolved>): ChatPlan[] => {
  const random = new SeededRandom(options.seed).fork("plan")
  const counts = distribute(options.messages, options.chats)
  const order = random.shuffle(counts.map((_, index) => index))
  const plans: ChatPlan[] = []
  for (let index = 0; index < options.chats; index += 1) {
    const id = FIRST_CHAT + BigInt(index)
    const messageCount = counts[order[index] ?? index] ?? 0
    const others = Array.from({ length: random.int(1, 6) }, () =>
      FIRST_USER + BigInt(random.int(0, options.users - 1)),
    )
    const participants = Array.from(new Set([options.selfUserId, ...others]))
    const parentCandidates = plans.filter((plan) => !plan.parent && plan.messageCount > 0)
    const parentPlan =
      parentCandidates.length > 0 && random.bool(options.threadShare)
        ? random.pick(parentCandidates)
        : undefined
    const plan: ChatPlan = {
      id,
      messageCount,
      ...(random.bool(0.7)
        ? { spaceId: FIRST_SPACE + BigInt(random.int(0, options.spaces - 1)) }
        : {}),
      ...(parentPlan
        ? {
            parent: {
              chatId: parentPlan.id,
              messageId: BigInt(random.int(1, parentPlan.messageCount)),
            },
          }
        : {}),
      readMaxId: 0n,
      unreadCount: 0,
      firstDate: options.startDateSeconds + random.int(0, 30 * 24 * 60 * 60),
      participants,
      script: random.weighted(scriptWeights),
    }
    const unreadTail = random.bool(0.3) ? random.int(1, Math.min(40, messageCount)) : 0
    plan.readMaxId = BigInt(Math.max(0, messageCount - unreadTail))
    // Count incoming messages past the read boundary from the author stream.
    const authors = authorStream(options.seed, id)
    for (let messageId = 1; messageId <= messageCount; messageId += 1) {
      const fromId = authorOf(authors, plan, options.selfUserId)
      if (BigInt(messageId) > plan.readMaxId && fromId !== options.selfUserId) {
        plan.unreadCount += 1
      }
    }
    plans.push(plan)
  }
  return plans
}

const entitiesFor = (
  random: SeededRandom,
  text: string,
  participants: bigint[],
): { text: string; entities: MessageEntity[] } | undefined => {
  if (!random.bool(0.2)) return undefined
  const roll = random.next()
  if (roll < 0.4) {
    const end = text.indexOf(" ")
    const length = end > 0 ? end : text.length
    return {
      text,
      entities: [
        { type: MessageEntity_Type.BOLD, offset: 0n, length: BigInt(length), entity: { oneofKind: undefined } },
      ],
    }
  }
  if (roll < 0.7) {
    const userId = random.pick(participants)
    const mention = `@user${userId}`
    return {
      text: `${mention} ${text}`,
      entities: [
        {
          type: MessageEntity_Type.MENTION,
          offset: 0n,
          length: BigInt(mention.length),
          entity: { oneofKind: "mention", mention: { userId } },
        },
      ],
    }
  }
  const url = `https://example.com/doc/${random.int(1, 99_999)}`
  return {
    text: `${text} ${url}`,
    entities: [
      {
        type: MessageEntity_Type.URL,
        offset: BigInt(text.length + 1),
        length: BigInt(url.length),
        entity: { oneofKind: undefined },
      },
    ],
  }
}

const photoFor = (random: SeededRandom, id: bigint, date: number): MessageMedia => {
  const landscape = random.bool(0.6)
  const w = landscape ? random.int(800, 4_000) : random.int(600, 2_000)
  const h = landscape ? Math.round((w * random.int(50, 80)) / 100) : Math.round((w * random.int(120, 180)) / 100)
  return {
    media: {
      oneofKind: "photo",
      photo: {
        photo: {
          id,
          date: BigInt(date),
          format: Photo_Format.JPEG,
          fileUniqueId: `seed-photo-${id}`,
          sizes: [
            { type: "s", w: Math.round(w / 20), h: Math.round(h / 20), size: random.int(800, 3_000) },
            { type: "y", w, h, size: random.int(150_000, 2_500_000) },
          ],
        },
      },
    },
  }
}

export function* generateSeedAccount(options: SeedAccountOptions): Generator<SeedRecord> {
  const config = resolved(options)
  const random = new SeededRandom(config.seed).fork("records")

  for (let index = 0; index < config.users; index += 1) {
    const id = FIRST_USER + BigInt(index)
    yield {
      kind: "user",
      user: { id, firstName: `${pickWord(random, random.weighted(scriptWeights))}`, lastName: `User ${id}`, min: true },
    }
  }
  yield { kind: "user", user: { id: config.selfUserId, firstName: "Self", min: false } }
  for (let index = 0; index < config.spaces; index += 1) {
    const id = FIRST_SPACE + BigInt(index)
    yield {
      kind: "space",
      space: { id, name: `Space ${index + 1}`, creator: index === 0, date: BigInt(config.startDateSeconds) },
    }
  }

  const plans = planChats(config)
  let photoId = 1n
  for (const plan of plans) {
    const messageRandom = random.fork(`messages:${plan.id}`)
    const authors = authorStream(config.seed, plan.id)
    // Dates: a steady walk from the chat's first message.
    const dateStep = () => messageRandom.int(5, 3_600)
    const lastDate = plan.firstDate + plan.messageCount * 1_800
    const chat: Chat = {
      id: plan.id,
      title: sentence(messageRandom, plan.script, messageRandom.int(1, 4)),
      peerId: chatPeer(plan.id),
      ...(plan.spaceId != null ? { spaceId: plan.spaceId } : {}),
      ...(plan.parent
        ? { parentChatId: plan.parent.chatId, parentMessageId: plan.parent.messageId }
        : {}),
      ...(plan.messageCount > 0 ? { lastMsgId: BigInt(plan.messageCount) } : {}),
      date: BigInt(lastDate),
    }
    const dialog: Dialog = {
      peer: chatPeer(plan.id),
      chatId: plan.id,
      ...(plan.spaceId != null ? { spaceId: plan.spaceId } : {}),
      readMaxId: plan.readMaxId,
      unreadCount: plan.unreadCount,
      unreadMark: false,
    }
    yield {
      kind: "chat",
      chat,
      dialog,
      messageCount: plan.messageCount,
      participants: plan.participants,
    }

    let date = plan.firstDate
    for (let id = 1n; id <= BigInt(plan.messageCount); id += 1n) {
      date = Math.min(lastDate, date + dateStep())
      const fromId = authorOf(authors, plan, config.selfUserId)
      const base = messageText(messageRandom, plan.script)
      const withEntities = entitiesFor(messageRandom, base, plan.participants)
      const replyTo = id > 1n && messageRandom.bool(0.1)
        ? BigInt(messageRandom.int(1, Number(id) - 1))
        : undefined
      const media = messageRandom.bool(0.05) ? photoFor(messageRandom, photoId++, date) : undefined
      yield {
        kind: "message",
        message: {
          id,
          fromId,
          chatId: plan.id,
          peerId: chatPeer(plan.id),
          message: withEntities?.text ?? base,
          out: fromId === config.selfUserId,
          date: BigInt(date),
          ...(replyTo != null ? { replyToMsgId: replyTo } : {}),
          ...(withEntities ? { entities: { entities: withEntities.entities } } : {}),
          ...(media ? { media } : {}),
        },
      }
    }
  }
}

export type SeedAccountSummary = {
  users: number
  spaces: number
  chats: number
  threads: number
  messages: number
  unread: number
}

/** Load a generated account into the server model, as history. */
export const seedServerModel = (
  model: ServerModel,
  options: Omit<SeedAccountOptions, "selfUserId">,
): SeedAccountSummary => {
  const summary: SeedAccountSummary = { users: 0, spaces: 0, chats: 0, threads: 0, messages: 0, unread: 0 }
  const heads = new Map<bigint, { count: number; date: number }>()
  for (const record of generateSeedAccount({ ...options, selfUserId: model.selfUserId })) {
    switch (record.kind) {
      case "user":
        if (record.user.id !== model.selfUserId) model.addUser(record.user.id, record.user.firstName)
        summary.users += 1
        break
      case "space":
        model.addSpace(record.space.id, record.space.name)
        summary.spaces += 1
        break
      case "chat":
        model.addChat({
          id: record.chat.id,
          title: record.chat.title,
          ...(record.chat.spaceId != null ? { spaceId: record.chat.spaceId } : {}),
          participants: record.participants,
        })
        model.setReadMaxId(record.chat.id, record.dialog.readMaxId ?? 0n)
        heads.set(record.chat.id, { count: record.messageCount, date: Number(record.chat.date ?? 0n) })
        summary.chats += 1
        summary.unread += record.dialog.unreadCount ?? 0
        if (record.chat.parentChatId != null) summary.threads += 1
        break
      case "message":
        model.importMessage({
          id: record.message.id,
          chatId: record.message.chatId,
          fromId: record.message.fromId,
          text: record.message.message ?? "",
          date: record.message.date,
          ...(record.message.replyToMsgId != null ? { replyToMsgId: record.message.replyToMsgId } : {}),
          reactions: [],
        })
        summary.messages += 1
        break
    }
  }
  for (const [chatId, head] of heads) {
    model.setBucketHead(`chat:${chatId}`, head.count, head.date)
  }
  return summary
}

/**
 * Write a generated account straight into a persistence store as replica
 * rows, `batchSize` rows per transaction, with each chat's sync cursor at its
 * head. Rows are built by the core's own mappers, so they match what sync
 * would have written.
 */
export const writeSeedAccountToStore = async (
  store: InlinePersistenceStore,
  options: SeedAccountOptions,
  writeOptions: { batchSize?: number; onBatch?: (written: number) => void } = {},
): Promise<SeedAccountSummary> => {
  const batchSize = writeOptions.batchSize ?? 2_000
  const summary: SeedAccountSummary = { users: 0, spaces: 0, chats: 0, threads: 0, messages: 0, unread: 0 }
  let batch: InlinePersistenceOperation[] = []
  let written = 0
  // A scratch Db per batch turns protocol records into rows with the real
  // mappers; it is dropped after every flush, so memory stays bounded.
  let scratch = new Db({ autoHydrate: false })
  const put = (object: DbModel | undefined) => {
    if (object) batch.push({ type: "put", object })
  }
  const flush = async () => {
    if (batch.length === 0) return
    await store.write(batch)
    written += batch.length
    writeOptions.onBatch?.(written)
    batch = []
    scratch = new Db({ autoHydrate: false })
  }

  for (const record of generateSeedAccount(options)) {
    switch (record.kind) {
      case "user":
        upsertUser(scratch, record.user)
        put(scratch.get(scratch.ref(DbObjectKind.User, makeUserId(record.user.id))))
        summary.users += 1
        break
      case "space":
        upsertSpace(scratch, record.space)
        put(scratch.get(scratch.ref(DbObjectKind.Space, makeSpaceId(record.space.id))))
        summary.spaces += 1
        break
      case "chat": {
        upsertChat(scratch, record.chat)
        upsertDialog(scratch, record.dialog)
        const chatId = makeChatId(record.chat.id)
        put(scratch.get(scratch.ref(DbObjectKind.Chat, chatId)))
        const dialogs = scratch.queryCollection<DbObjectKind.Dialog, DbDialog, DbQueryPlanType.Objects>(
          DbQueryPlanType.Objects,
          DbObjectKind.Dialog,
          (candidate) => candidate.chatId === chatId,
        )
        for (const row of dialogs) put(row)
        put({
          kind: DbObjectKind.SyncBucketState,
          id: syncBucketId({ kind: "chat", peer: chatPeer(record.chat.id) }),
          seq: record.messageCount,
          date: Number(record.chat.date ?? 0n),
        })
        summary.chats += 1
        summary.unread += record.dialog.unreadCount ?? 0
        if (record.chat.parentChatId != null) summary.threads += 1
        break
      }
      case "message":
        put(messageModel(record.message))
        summary.messages += 1
        break
    }
    if (batch.length >= batchSize) await flush()
  }
  await flush()
  return summary
}
