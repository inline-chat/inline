import { describe, expect, it, vi } from "vitest"
import { Method, ProtocolClientError, type User } from "@inline-chat/realtime-sdk"
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
      bot: false,
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
      bot: false,
    })
    expect(calls).toEqual([Method.GET_CHATS])
  })

  it.each(["direct", "participants", "directory"])("refreshes a successful missing-sender lookup before the positive TTL (%s)", async source => {
    let now = 0
    let present = false
    const calls: Method[] = []
    const direct = source === "direct"
    const directory = new InlineUserDirectory({
      async invokeUncheckedRaw(method) {
        calls.push(method)
        await Promise.resolve()
        const kind = method === Method.GET_CHAT_PARTICIPANTS ? "getChatParticipants" : "getChats"
        const matchingSource = source === "participants" ? method === Method.GET_CHAT_PARTICIPANTS : method === Method.GET_CHATS
        return { oneofKind: kind, [kind]: { users: [
          user(41n, { firstName: "Already known" }),
          ...(present && matchingSource ? [user(42n, { firstName: "New sender" })] : []),
        ] } }
      },
    }, { now: () => now })
    const lookup = (userId: bigint) => directory.resolveWithProvenance({ userId, chatId: 7n, direct })
    await expect(lookup(41n)).resolves.toMatchObject({ provenanceVerified: true, profile: { id: "41", bot: false } })
    await expect(lookup(42n)).resolves.toEqual({ provenanceVerified: false })
    const firstCalls = direct ? [Method.GET_CHATS] : [Method.GET_CHAT_PARTICIPANTS, Method.GET_CHATS]
    expect(calls).toEqual(firstCalls)

    now = 999
    expect(await Promise.all(Array.from({ length: 20 }, () => lookup(42n))))
      .toEqual(Array.from({ length: 20 }, () => ({ provenanceVerified: false })))
    await Promise.all(Array.from({ length: 20 }, () => lookup(41n)))
    expect(calls).toEqual(firstCalls)

    now = 1_000
    expect(await Promise.all(Array.from({ length: 20 }, () => lookup(42n))))
      .toEqual(Array.from({ length: 20 }, () => ({ provenanceVerified: false })))
    expect(calls).toEqual([...firstCalls, ...firstCalls])

    present = true
    now = 1_999
    await expect(lookup(42n)).resolves.toEqual({ provenanceVerified: false })
    expect(calls).toEqual([...firstCalls, ...firstCalls])
    now = 2_000
    const recovered = await Promise.all(Array.from({ length: 20 }, () => lookup(42n)))
    expect(recovered).toEqual(Array.from({ length: 20 }, () => ({
      profile: { id: "42", firstName: "New sender", bot: false }, provenanceVerified: true,
    })))
    expect(calls).toEqual([...firstCalls, ...firstCalls,
      ...(source === "participants" ? [Method.GET_CHAT_PARTICIPANTS] : firstCalls),
    ])
    const recoveredCalls = [...calls]
    now = 20_000
    await Promise.all(Array.from({ length: 20 }, () => lookup(42n)))
    await Promise.all(Array.from({ length: 20 }, () => lookup(41n)))
    expect(calls).toEqual(recoveredCalls)
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

  it("marks sender provenance unverified when participant and directory hydration fail", async () => {
    const directory = new InlineUserDirectory({
      async invokeUncheckedRaw() {
        throw new Error("directory unavailable")
      },
    })

    await expect(directory.resolveWithProvenance({ userId: 5n, chatId: 10n, direct: false }))
      .resolves.toEqual({ provenanceVerified: false })
  })

  it("requires authoritative proof for the matching sender, preserving known bot kind across partial updates", async () => {
    const directory = new InlineUserDirectory({
      async invokeUncheckedRaw() {
        return { oneofKind: "getChats", getChats: { users: [
          user(1n, { firstName: "Worker", bot: true }), user(2n, { firstName: "Human" }),
        ] } }
      },
    })
    directory.remember([user(42n, { firstName: "Unverified partial", bot: false })])
    await expect(directory.resolveWithProvenance({ userId: 42n, chatId: 8n, direct: true }))
      .resolves.toMatchObject({ profile: { id: "42", bot: false }, provenanceVerified: false })
    await expect(directory.resolveWithProvenance({ userId: 2n, chatId: 8n, direct: true }))
      .resolves.toMatchObject({ profile: { id: "2", bot: false }, provenanceVerified: true })
    directory.remember([user(1n, { username: "worker_updated" })])
    await expect(directory.resolveWithProvenance({ userId: 1n, chatId: 8n, direct: true }))
      .resolves.toMatchObject({ profile: { id: "1", username: "worker_updated", bot: true }, provenanceVerified: true })
  })

  it("does not let partial profile refreshes extend expired sender-kind proof", async () => {
    let now = 0
    const directory = new InlineUserDirectory({
      async invokeUncheckedRaw() {
        if (now > 10) throw new Error("Current directory unavailable")
        return { oneofKind: "getChats", getChats: { users: [user(42n, { firstName: "Ada" })] } }
      },
    }, { now: () => now, ttlMs: 10 })
    await expect(directory.resolveWithProvenance({ userId: 42n, chatId: 8n, direct: true }))
      .resolves.toMatchObject({ profile: { bot: false }, provenanceVerified: true })
    now = 9
    directory.remember([user(42n, { username: "ada_updated" })])
    now = 11
    await expect(directory.resolveWithProvenance({ userId: 42n, chatId: 8n, direct: true }))
      .resolves.toMatchObject({ profile: { id: "42", username: "ada_updated" }, provenanceVerified: false })
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


it.each([false, true])("a consistently slow directory can recover after an initial fast timeout (direct=%s)", async direct => {
  vi.useFakeTimers()
  try {
    const directory = new InlineUserDirectory({
      async invokeUncheckedRaw(method, _input, options) {
        const kind = method === Method.GET_CHAT_PARTICIPANTS ? "getChatParticipants" : "getChats"
        if (!direct && method === Method.GET_CHATS) return {oneofKind: kind, [kind]: {users: []}}
        let responseTimer: ReturnType<typeof setTimeout> | undefined
        let timeoutTimer: ReturnType<typeof setTimeout> | undefined
        try {
          return await new Promise((resolve, reject) => {
            responseTimer = setTimeout(() => resolve({oneofKind: kind, [kind]: {users: [user(42n, {bot: false})]}}), 2_000)
            timeoutTimer = setTimeout(() => reject(new ProtocolClientError("timeout")), options?.timeoutMs ?? 30_000)
          })
        } finally { clearTimeout(responseTimer); clearTimeout(timeoutTimer) }
      },
    })
    const first = directory.resolveWithProvenance({userId: 42n, chatId: 7n, direct})
    await vi.advanceTimersByTimeAsync(1_501)
    expect((await first).provenanceVerified).toBe(false)
    const retry = directory.resolveWithProvenance({userId: 42n, chatId: 7n, direct})
    await vi.advanceTimersByTimeAsync(2_001)
    expect(await retry).toMatchObject({provenanceVerified: true, profile: {id: "42", bot: false}})
  } finally { vi.useRealTimers() }
})
