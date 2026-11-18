import { GetChatHistoryMode, GetChatsInput, Method, type RpcCall } from "@inline-chat/protocol/core"
import { describe, expect, it } from "vitest"
import { createDemoAccount, DEMO_SCALES } from "./demo-account"
import { DemoLazyMessages } from "./demo-lazy-messages"
import { demoNames, isDemoCommand } from "./demo-protocol"
import { DEMO_RESTORE_MARGIN, DemoServerModel, isDemoPersistedState } from "./demo-server-model"
import { SeededRandom } from "./rng"
import { chatInputPeer, type ModelMessage } from "./server-model"

const ANCHOR = 1_800_000_000

const message = (id: bigint): ModelMessage => ({
  id,
  chatId: 1n,
  fromId: 2n,
  text: `m${id}`,
  date: id,
  reactions: [],
})

describe("DemoLazyMessages", () => {
  it("pages like a plain map over seeded, added and deleted messages", () => {
    const random = new SeededRandom(11)
    for (let round = 0; round < 30; round += 1) {
      const count = random.int(0, 120)
      const lazy = new DemoLazyMessages(count, message)
      const plain = new Map<bigint, ModelMessage>()
      for (let id = 1n; id <= BigInt(count); id += 1n) plain.set(id, message(id))
      for (let step = 0; step < 40; step += 1) {
        const id = BigInt(random.int(1, count + 30))
        if (random.bool(0.5)) {
          lazy.set(id, message(id))
          plain.set(id, message(id))
        } else {
          lazy.delete(id)
          plain.delete(id)
        }
      }
      const sorted = Array.from(plain.keys()).sort((left, right) => (left < right ? -1 : 1))
      for (let probe = 0; probe < 20; probe += 1) {
        const pivot = BigInt(random.int(0, count + 32))
        const limit = random.int(1, 60)
        expect(lazy.idsBefore(pivot, limit)).toEqual(
          sorted.filter((id) => id < pivot).reverse().slice(0, limit),
        )
        expect(lazy.idsAfter(pivot, limit)).toEqual(sorted.filter((id) => id > pivot).slice(0, limit))
      }
      expect(lazy.idsBefore(undefined, 5)).toEqual(sorted.slice().reverse().slice(0, 5))
      expect(lazy.latest()?.id).toBe(sorted.at(-1))
      expect(lazy.materialized).toBe(false)
      // Iterating materializes and agrees with the plain map.
      expect(Array.from(lazy.keys()).sort((left, right) => (left < right ? -1 : 1))).toEqual(sorted)
      expect(lazy.size).toBe(plain.size)
      expect(lazy.materialized).toBe(true)
    }
  })

  it("keeps the object `get` returned, so edits stick", () => {
    const lazy = new DemoLazyMessages(10, message)
    lazy.get(4n)!.text = "edited"
    expect(lazy.get(4n)!.text).toBe("edited")
    expect(lazy.peek(5n)!.text).toBe("m5")
    expect(lazy.stored().map((stored) => stored.id)).toEqual([4n])
  })
})

describe("createDemoAccount", () => {
  it("is deterministic and matches its scale", () => {
    const one = createDemoAccount({ seed: 3, scale: "small", anchor: ANCHOR })
    const two = createDemoAccount({ seed: 3, scale: "small", anchor: ANCHOR })
    expect(one.chats).toHaveLength(DEMO_SCALES.small.chats)
    expect(one.totalMessages).toBe(DEMO_SCALES.small.messages)
    const chat = one.chats.find((candidate) => candidate.count > 10)!
    expect(one.messageAt(chat, 7n)).toEqual(two.messageAt(two.chats.find((c) => c.id === chat.id)!, 7n))
    // Dates rise with IDs and end at the chat's last activity.
    const dates = Array.from({ length: chat.count }, (_, index) =>
      Number(one.messageAt(chat, BigInt(index + 1)).date),
    )
    expect(dates).toEqual(dates.slice().sort((left, right) => left - right))
    expect(dates.at(-1)).toBe(chat.lastDate)
    expect(one.chats.some((candidate) => candidate.pinned)).toBe(true)
    expect(one.chats.some((candidate) => candidate.readMaxId < BigInt(candidate.count))).toBe(true)
  })
})

describe("DemoServerModel", () => {
  const model = () => {
    const account = createDemoAccount({ seed: 5, scale: "small", anchor: ANCHOR })
    const server = new DemoServerModel(account, { now: () => ANCHOR })
    for (const plan of account.chats) server.installChat(plan)
    const busiest = account.chats.slice().sort((left, right) => right.count - left.count)[0]!
    return { account, server, busiest }
  }

  const history = (server: DemoServerModel, input: Omit<Extract<RpcCall["input"], { oneofKind: "getChatHistory" }>["getChatHistory"], "peerId">, chatId: bigint) => {
    const outcome = server.handleRpc(1, Method.GET_CHAT_HISTORY, {
      oneofKind: "getChatHistory",
      getChatHistory: { peerId: chatInputPeer(chatId), ...input },
    })
    if (!("result" in outcome) || outcome.result.oneofKind !== "getChatHistory") {
      throw new Error("expected history")
    }
    return outcome.result.getChatHistory.messages.map((entry) => Number(entry.id))
  }

  it("answers every history mode newest first without materializing, skipping seeded holes", () => {
    const { account, server, busiest } = model()
    const present = Array.from({ length: busiest.count }, (_, index) => index + 1).filter(
      (id) => !account.holeAt(busiest, BigInt(id)),
    )
    expect(present.length).toBeLessThan(busiest.count)
    const below = (id: number, count: number) => present.filter((candidate) => candidate < id).reverse().slice(0, count)
    const above = (id: number, count: number) => present.filter((candidate) => candidate > id).slice(0, count)
    expect(history(server, { mode: GetChatHistoryMode.HISTORY_MODE_LATEST, limit: 3 }, busiest.id)).toEqual(
      below(busiest.count + 1, 3),
    )
    expect(
      history(server, { mode: GetChatHistoryMode.HISTORY_MODE_OLDER, beforeId: 40n, limit: 3 }, busiest.id),
    ).toEqual(below(40, 3))
    expect(
      history(server, { mode: GetChatHistoryMode.HISTORY_MODE_NEWER, afterId: 40n, limit: 3 }, busiest.id),
    ).toEqual(above(40, 3).reverse())
    const anchor = present[60]!
    expect(
      history(
        server,
        { mode: GetChatHistoryMode.HISTORY_MODE_AROUND, anchorId: BigInt(anchor), beforeLimit: 2, afterLimit: 2, includeAnchor: true },
        busiest.id,
      ),
    ).toEqual([...above(anchor, 2).reverse(), anchor, ...below(anchor, 2)])
    expect(server.materializedChats()).toBe(0)
  })

  it("answers getChats from the plan, with sidebar fields and exact unread counts", () => {
    const { account, server } = model()
    const outcome = server.handleRpc(1, Method.GET_CHATS, { oneofKind: "getChats", getChats: GetChatsInput.create() })
    if (!("result" in outcome) || outcome.result.oneofKind !== "getChats") throw new Error("expected chats")
    const { dialogs, chats } = outcome.result.getChats
    expect(chats).toHaveLength(account.chats.length)
    for (const plan of account.chats) {
      const dialog = dialogs.find((candidate) => candidate.chatId === plan.id)!
      expect(dialog).toMatchObject({ pinned: plan.pinned, archived: plan.archived, open: plan.open })
      let unread = 0
      for (let id = plan.readMaxId + 1n; id <= BigInt(plan.count); id += 1n) {
        if (!account.holeAt(plan, id) && account.authorAt(plan, id) !== account.selfUserId) unread += 1
      }
      expect(dialog.unreadCount).toBe(unread)
    }
    expect(server.materializedChats()).toBe(0)
  })

  it("saves and restores its changes, past a margin", () => {
    const { server, busiest } = model()
    server.postMessage({ chatId: busiest.id, fromId: busiest.others[0]!, text: "new" })
    server.editMessage(busiest.id, 3n, "edited seeded")
    server.deleteMessages(busiest.id, [4n])
    const state = JSON.parse(JSON.stringify(server.persistedState())) as unknown
    expect(isDemoPersistedState(state)).toBe(true)

    const restored = model()
    restored.server.restore(state as never)
    const chat = restored.server.chatState(busiest.id)
    expect(chat.messages.find((entry) => entry.id === 3n)?.text).toBe("edited seeded")
    expect(chat.messages.some((entry) => entry.id === 4n)).toBe(false)
    expect(chat.messages.at(-1)?.text).toBe("new")
    expect(restored.server.bucketSeq(`chat:${busiest.id}`)).toBe(
      server.bucketSeq(`chat:${busiest.id}`) + DEMO_RESTORE_MARGIN,
    )
    const next = restored.server.postMessage({ chatId: busiest.id, fromId: busiest.others[0]!, text: "after" })
    expect(next.id).toBe(BigInt(busiest.count) + 2n + BigInt(DEMO_RESTORE_MARGIN))
  })
})

describe("demo protocol", () => {
  it("accepts well-formed commands only", () => {
    expect(isDemoCommand({ kind: "deliver", chatId: "1000" })).toBe(true)
    expect(isDemoCommand({ kind: "stream", action: "start", ratePerSecond: 5 })).toBe(true)
    expect(isDemoCommand({ kind: "otherUser", action: "react", chatId: "1000", emoji: "🎉" })).toBe(true)
    expect(isDemoCommand({ kind: "deliver", chatId: 1000 })).toBe(false)
    expect(isDemoCommand({ kind: "otherUser", action: "ban", chatId: "1000" })).toBe(false)
    expect(isDemoCommand({ kind: "faults", latencyMs: Number.NaN, lossRate: 0 })).toBe(false)
    expect(isDemoCommand("deliver")).toBe(false)
  })

  it("keeps demos apart from each other and from real accounts", () => {
    const a = demoNames({ scale: "small", seed: 1, storage: "opfs" })
    const b = demoNames({ scale: "large", seed: 1, storage: "opfs" })
    expect(a.origin).not.toBe(b.origin)
    expect(a.namespace).not.toBe(b.namespace)
    expect(a.origin.startsWith("inline-demo://")).toBe(true)
  })
})
