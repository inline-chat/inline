import { describe, expect, it } from "vitest"
import { Method, type User } from "@inline-chat/realtime-sdk"
import { InlineUserDirectory } from "./user-directory.js"

const user = (id: bigint, values: Partial<User> = {}): User => ({ id, ...values })

describe("InlineUserDirectory", () => {
  it("hydrates group senders once and merges partial profiles", async () => {
    const calls: Method[] = []
    const directory = new InlineUserDirectory({
      async invokeUncheckedRaw(method) {
        calls.push(method)
        return {
          oneofKind: "getChatParticipants",
          getChatParticipants: {
            users: [user(42n, { firstName: "Ada", lastName: "Lovelace", username: "ada" })],
          },
        }
      },
    })

    await expect(directory.resolve({ userId: 42n, chatId: 7n, direct: false })).resolves.toEqual({
      id: "42",
      firstName: "Ada",
      lastName: "Lovelace",
      username: "ada",
    })
    await expect(directory.resolve({ userId: 42n, chatId: 7n, direct: false })).resolves.toMatchObject({ firstName: "Ada" })
    expect(calls).toEqual([Method.GET_CHAT_PARTICIPANTS])

    directory.remember([user(42n, { username: "ada_updated" })])
    await expect(directory.resolve({ userId: 42n, chatId: 7n, direct: false })).resolves.toMatchObject({
      firstName: "Ada",
      lastName: "Lovelace",
      username: "ada_updated",
    })
  })

  it("uses the cached chats directory for direct senders", async () => {
    const calls: Method[] = []
    const directory = new InlineUserDirectory({
      async invokeUncheckedRaw(method) {
        calls.push(method)
        return {
          oneofKind: "getChats",
          getChats: { users: [user(91n, { username: "fallback" })] },
        }
      },
    })

    await expect(directory.resolve({ userId: 91n, chatId: 8n, direct: true })).resolves.toEqual({
      id: "91",
      username: "fallback",
    })
    expect(calls).toEqual([Method.GET_CHATS])
  })

  it("falls back to the directory when participants contain only an id", async () => {
    const calls: Method[] = []
    const directory = new InlineUserDirectory({
      async invokeUncheckedRaw(method) {
        calls.push(method)
        if (method === Method.GET_CHAT_PARTICIPANTS) {
          return { oneofKind: "getChatParticipants", getChatParticipants: { users: [user(42n)] } }
        }
        return {
          oneofKind: "getChats",
          getChats: { users: [user(42n, { firstName: "Ada", username: "ada" })] },
        }
      },
    })

    await expect(directory.resolve({ userId: 42n, chatId: 7n, direct: false })).resolves.toMatchObject({
      firstName: "Ada",
      username: "ada",
    })
    expect(calls).toEqual([Method.GET_CHAT_PARTICIPANTS, Method.GET_CHATS])
  })

  it("deduplicates concurrent hydration and retries failures", async () => {
    let attempts = 0
    const errors: string[] = []
    const directory = new InlineUserDirectory({
      async invokeUncheckedRaw() {
        attempts += 1
        if (attempts === 1) throw new Error("temporary")
        await Promise.resolve()
        return {
          oneofKind: "getChatParticipants",
          getChatParticipants: { users: [user(5n, { firstName: "Lin" })] },
        }
      },
    }, {
      onError: (operation) => errors.push(operation),
    })

    await expect(directory.resolve({ userId: 5n, chatId: 10n, direct: false })).resolves.toBeUndefined()
    expect(errors).toEqual(["getChatParticipants"])
    await Promise.all([
      directory.resolve({ userId: 5n, chatId: 10n, direct: false }),
      directory.resolve({ userId: 5n, chatId: 10n, direct: false }),
    ])
    expect(attempts).toBe(3)
  })

  it("expires cached profiles and bounds the cache", async () => {
    let now = 0
    let requests = 0
    const directory = new InlineUserDirectory({
      async invokeUncheckedRaw() {
        requests += 1
        return {
          oneofKind: "getChats",
          getChats: { users: [user(1n, { firstName: `Name ${requests}` })] },
        }
      },
    }, { ttlMs: 10, maxProfiles: 2, now: () => now })

    directory.remember([user(2n, { firstName: "Two" }), user(3n, { firstName: "Three" })])
    await expect(directory.resolve({ userId: 2n, chatId: 1n, direct: true })).resolves.toMatchObject({ firstName: "Two" })
    directory.remember([user(4n, { firstName: "Four" })])
    now = 11
    await expect(directory.resolve({ userId: 1n, chatId: 1n, direct: true })).resolves.toMatchObject({ firstName: "Name 1" })
    expect(requests).toBe(1)
  })

  it("bounds hydrated chat markers", async () => {
    let requests = 0
    const directory = new InlineUserDirectory({
      async invokeUncheckedRaw() {
        requests += 1
        return { oneofKind: "getChatParticipants", getChatParticipants: { users: [] } }
      },
    }, { maxProfiles: 2 })

    await directory.resolve({ userId: 91n, chatId: 1n, direct: false })
    await directory.resolve({ userId: 91n, chatId: 2n, direct: false })
    await directory.resolve({ userId: 91n, chatId: 3n, direct: false })
    await directory.resolve({ userId: 91n, chatId: 1n, direct: false })

    expect(requests).toBe(5)
  })
})
