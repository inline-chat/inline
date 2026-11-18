import { afterEach, describe, expect, it } from "vitest"
import { chatId } from "@inline/ids"
import { DbObjectKind } from "../database/models"
import { CrashableDisk } from "./crashable-disk"
import {
  SEED_ACCOUNT_SCALES,
  generateSeedAccount,
  seedServerModel,
  writeSeedAccountToStore,
  type SeedRecord,
} from "./seed-account"
import { ServerModel } from "./server-model"

const stringify = (records: SeedRecord[]) =>
  JSON.stringify(records, (_, value: unknown) =>
    typeof value === "bigint" ? `${value}n` : value,
  )

const take = (iterator: Iterator<SeedRecord>, count: number) => {
  const records: SeedRecord[] = []
  for (let index = 0; index < count; index += 1) {
    const next = iterator.next()
    if (next.done) break
    records.push(next.value)
  }
  return records
}

describe("seeded account generator", () => {
  let disk: CrashableDisk | undefined
  afterEach(async () => {
    await disk?.dispose()
    disk = undefined
  })

  it("is deterministic for a seed and different across seeds", () => {
    const first = take(generateSeedAccount({ seed: 7, ...SEED_ACCOUNT_SCALES.small }), 400)
    const again = take(generateSeedAccount({ seed: 7, ...SEED_ACCOUNT_SCALES.small }), 400)
    const other = take(generateSeedAccount({ seed: 8, ...SEED_ACCOUNT_SCALES.small }), 400)
    expect(stringify(again)).toBe(stringify(first))
    expect(stringify(other)).not.toBe(stringify(first))
  })

  it("streams: the first message of the large account comes without generating the rest", () => {
    const iterator = generateSeedAccount({ seed: 1, ...SEED_ACCOUNT_SCALES.large })
    let next = iterator.next()
    while (!next.done && next.value.kind !== "message") next = iterator.next()
    expect(next.done).toBe(false)
  })

  it("produces mixed scripts, long messages, entities, replies, threads and photos", () => {
    const messages: Array<Extract<SeedRecord, { kind: "message" }>["message"]> = []
    let threads = 0
    const unreadByChat = new Map<bigint, { readMaxId: bigint; expected: number; incoming: number }>()
    for (const record of generateSeedAccount({ seed: 3, ...SEED_ACCOUNT_SCALES.small })) {
      if (record.kind === "chat") {
        if (record.chat.parentChatId != null) threads += 1
        unreadByChat.set(record.chat.id, {
          readMaxId: record.dialog.readMaxId ?? 0n,
          expected: record.dialog.unreadCount ?? 0,
          incoming: 0,
        })
      }
      if (record.kind === "message") {
        messages.push(record.message)
        const unread = unreadByChat.get(record.message.chatId)!
        if (!record.message.out && record.message.id > unread.readMaxId) unread.incoming += 1
      }
    }
    expect(messages).toHaveLength(SEED_ACCOUNT_SCALES.small.messages)
    const texts = messages.map((message) => message.message ?? "")
    expect(texts.some((text) => /[؀-ۿ]/.test(text))).toBe(true) // Arabic
    expect(texts.some((text) => /[֐-׿]/.test(text))).toBe(true) // Hebrew
    expect(texts.some((text) => /[一-鿿]/.test(text))).toBe(true) // CJK
    expect(texts.some((text) => text.length > 1_000 && text.includes("\n\n"))).toBe(true)
    expect(messages.some((message) => message.replyToMsgId != null)).toBe(true)
    expect(messages.some((message) => message.media?.media.oneofKind === "photo")).toBe(true)
    expect(threads).toBeGreaterThan(0)
    // Entity ranges index their text.
    for (const message of messages) {
      for (const entity of message.entities?.entities ?? []) {
        const end = Number(entity.offset + entity.length)
        expect(end).toBeLessThanOrEqual((message.message ?? "").length)
      }
    }
    // The dialog's unread count is exact.
    for (const unread of unreadByChat.values()) expect(unread.incoming).toBe(unread.expected)
  })

  it("writes replica rows in batches that the core's indexed reads can use", async () => {
    disk = new CrashableDisk()
    const store = disk.openStore()
    const batches: number[] = []
    const summary = await writeSeedAccountToStore(
      store,
      { seed: 5, chats: 40, messages: 5_000 },
      { batchSize: 1_000, onBatch: (written) => batches.push(written) },
    )
    expect(summary.messages).toBe(5_000)
    expect(batches.length).toBeGreaterThan(4)

    const chats = await store.collection(DbObjectKind.Chat).getAll()
    expect(chats).toHaveLength(40)
    const busiest = chats.reduce((max, chat) =>
      Number(chat.lastMsgId ?? 0) > Number(max.lastMsgId ?? 0) ? chat : max,
    )
    const window = await store
      .collection(DbObjectKind.Message)
      .getMessageWindowByChatId?.(chatId(busiest.id), 50)
    expect(window).toHaveLength(50)
    expect((await store.collection(DbObjectKind.Dialog).getAll()).length).toBe(40)
  })

  it("loads into the server model as journal-pruned history", () => {
    const model = new ServerModel({ now: () => 1_800_000_000 })
    const summary = seedServerModel(model, { seed: 9, chats: 10, messages: 500 })
    expect(summary.messages).toBe(500)
    const totalUnread = Array.from(model.chats.keys()).reduce(
      (sum, id) => sum + model.unreadCount(id),
      0,
    )
    expect(totalUnread).toBe(summary.unread)
    const [first] = model.chats.keys()
    expect(model.bucketSeq(`chat:${first!}`)).toBe(model.chatState(first!).messages.length)
  })
})
