import { describe, expect, it, vi } from "vitest"
import { InlineSenderProfileCache } from "./sender-profile-cache.js"

describe("InlineSenderProfileCache", () => {
  it("hydrates participants once and merges partial profiles", async () => {
    const fetchChatParticipants = vi.fn(async () => [
      { id: 42n, firstName: "Ada" },
      { id: 42n, lastName: "Lovelace", username: "@ada" },
    ])
    const fetchUsers = vi.fn(async () => [])
    const cache = new InlineSenderProfileCache({ fetchChatParticipants, fetchUsers })

    await expect(cache.resolve({ userId: "42", chatId: 7n })).resolves.toEqual({
      name: "Ada Lovelace",
      username: "ada",
    })
    await cache.resolve({ userId: "42", chatId: 7n })

    expect(fetchChatParticipants).toHaveBeenCalledTimes(1)
    expect(fetchUsers).not.toHaveBeenCalled()
  })

  it("preserves bot identity across partial profile hydration", async () => {
    const fetchChatParticipants = vi.fn(async () => [
      { id: 42n, firstName: "Research Bot", bot: true },
      { id: 42n, username: "research", bot: undefined },
    ])
    const cache = new InlineSenderProfileCache({
      fetchChatParticipants,
      fetchUsers: vi.fn(async () => []),
    })

    await expect(cache.resolve({ userId: "42", chatId: 7n })).resolves.toEqual({
      name: "Research Bot",
      username: "research",
      bot: true,
    })
  })

  it("uses one user lookup for concurrent participant misses", async () => {
    const fetchChatParticipants = vi.fn(async () => [])
    const fetchUsers = vi.fn(async () => [{ id: 42n, firstName: "Ada" }])
    const cache = new InlineSenderProfileCache({ fetchChatParticipants, fetchUsers })

    const [first, second] = await Promise.all([
      cache.resolve({ userId: "42", chatId: 7n }),
      cache.resolve({ userId: "42", chatId: 7n }),
    ])

    expect(first).toEqual({ name: "Ada" })
    expect(second).toEqual({ name: "Ada" })
    expect(fetchChatParticipants).toHaveBeenCalledTimes(1)
    expect(fetchUsers).toHaveBeenCalledTimes(1)
  })

  it("looks the user up when a participant record has no display identity", async () => {
    const fetchChatParticipants = vi.fn(async () => [{ id: 42n }])
    const fetchUsers = vi.fn(async () => [{ id: 42n, firstName: "Ada", username: "ada" }])
    const cache = new InlineSenderProfileCache({ fetchChatParticipants, fetchUsers })

    await expect(cache.resolve({ userId: "42", chatId: 7n })).resolves.toEqual({
      name: "Ada",
      username: "ada",
    })
    expect(fetchUsers).toHaveBeenCalledTimes(1)
  })

  it("hydrates a new chat even when its current sender is already cached", async () => {
    const fetchChatParticipants = vi.fn(async () => [{ id: 7n, firstName: "Grace" }])
    const fetchUsers = vi.fn(async () => [])
    const cache = new InlineSenderProfileCache({ fetchChatParticipants, fetchUsers })
    cache.remember([{ id: 42n, firstName: "Ada" }])

    await expect(cache.resolve({ userId: "42", chatId: 7n })).resolves.toEqual({ name: "Ada" })

    expect(fetchChatParticipants).toHaveBeenCalledTimes(1)
    expect(cache.get("7")).toEqual({ name: "Grace" })
    expect(fetchUsers).not.toHaveBeenCalled()
  })

  it("expires hydration state and retries failed fetches", async () => {
    let now = 100
    const fetchChatParticipants = vi.fn()
      .mockRejectedValueOnce(new Error("temporary"))
      .mockResolvedValue([{ id: 42n, username: "ada" }])
    const fetchUsers = vi.fn(async () => [])
    const onError = vi.fn()
    const cache = new InlineSenderProfileCache({
      fetchChatParticipants,
      fetchUsers,
      onError,
      ttlMs: 10,
      now: () => now,
    })

    await expect(cache.resolve({ userId: "42", chatId: 7n })).resolves.toBeUndefined()
    await expect(cache.resolve({ userId: "42", chatId: 7n })).resolves.toEqual({ username: "ada" })
    now = 111
    await expect(cache.resolve({ userId: "42", chatId: 7n })).resolves.toEqual({ username: "ada" })

    expect(fetchChatParticipants).toHaveBeenCalledTimes(3)
    expect(fetchUsers).toHaveBeenCalledTimes(1)
    expect(onError).toHaveBeenCalledWith("getChatParticipants", expect.any(Error))
  })

  it("retries a failed user lookup", async () => {
    const fetchChatParticipants = vi.fn(async () => [])
    const fetchUsers = vi.fn()
      .mockRejectedValueOnce(new Error("temporary"))
      .mockResolvedValue([{ id: 42n, firstName: "Ada" }])
    const onError = vi.fn()
    const cache = new InlineSenderProfileCache({ fetchChatParticipants, fetchUsers, onError })

    await expect(cache.resolve({ userId: "42", chatId: 7n })).resolves.toBeUndefined()
    await expect(cache.resolve({ userId: "42", chatId: 7n })).resolves.toEqual({ name: "Ada" })

    expect(fetchChatParticipants).toHaveBeenCalledTimes(1)
    expect(fetchUsers).toHaveBeenCalledTimes(2)
    expect(onError).toHaveBeenCalledWith("getUsers", expect.any(Error))
  })

  it("asks only for the missing sender, never the whole directory", async () => {
    const fetchChatParticipants = vi.fn(async () => [])
    const fetchUsers = vi.fn(async (ids: readonly bigint[]) => ids.map((id) => ({ id, firstName: `User ${id}` })))
    const cache = new InlineSenderProfileCache({ fetchChatParticipants, fetchUsers })

    await expect(cache.resolve({ userId: "42", chatId: 7n })).resolves.toEqual({ name: "User 42" })
    await expect(cache.resolve({ userId: "43", chatId: 7n })).resolves.toEqual({ name: "User 43" })
    await cache.resolve({ userId: "42", chatId: 7n })

    expect(fetchUsers.mock.calls).toEqual([[[42n]], [[43n]]])
  })

  it("marks sender provenance unverified when both hydration paths fail", async () => {
    const cache = new InlineSenderProfileCache({
      fetchChatParticipants: vi.fn(async () => { throw new Error("participants unavailable") }),
      fetchUsers: vi.fn(async () => { throw new Error("directory unavailable") }),
    })

    await expect(cache.resolveWithProvenance({ userId: "42", chatId: 7n })).resolves.toEqual({
      provenanceVerified: false,
    })
  })

  it("bounds profiles and makes evicted users immediately fetchable", async () => {
    const fetchChatParticipants = vi.fn(async () => [{ id: 1n, firstName: "One" }])
    const fetchUsers = vi.fn(async () => [])
    const cache = new InlineSenderProfileCache({ fetchChatParticipants, fetchUsers, maxProfiles: 2 })

    cache.remember([
      { id: 1n, firstName: "One" },
      { id: 2n, firstName: "Two" },
      { id: 3n, firstName: "Three" },
    ])
    expect(cache.get("1")).toBeUndefined()
    expect(cache.get("2")).toEqual({ name: "Two" })
    expect(cache.get("3")).toEqual({ name: "Three" })

    await expect(cache.resolve({ userId: "1", chatId: 7n })).resolves.toEqual({ name: "One" })
    expect(fetchChatParticipants).toHaveBeenCalledTimes(1)
  })

  it("bounds hydrated chat markers", async () => {
    const fetchChatParticipants = vi.fn(async () => [])
    const fetchUsers = vi.fn(async () => [])
    const cache = new InlineSenderProfileCache({ fetchChatParticipants, fetchUsers, maxProfiles: 2 })

    await cache.hydrateChat(1n)
    await cache.hydrateChat(2n)
    await cache.hydrateChat(3n)
    await cache.hydrateChat(1n)

    expect(fetchChatParticipants).toHaveBeenCalledTimes(4)
  })

  it("names many unknown users with one batched lookup and remembers misses", async () => {
    let now = 1_000
    const fetchChatParticipants = vi.fn(async () => [])
    const fetchUsers = vi.fn(async (ids: readonly bigint[]) =>
      ids.filter((id) => id !== 99n).map((id) => ({ id, firstName: `User ${id}` })),
    )
    const cache = new InlineSenderProfileCache({ fetchChatParticipants, fetchUsers, now: () => now })
    cache.remember([{ id: 1n, firstName: "Known" }])

    const ids = ["1", "2", "3", "3", "99", "0", "x", ...Array.from({ length: 50 }, (_, i) => String(100 + i))]
    await cache.ensureUsers(ids)

    expect(fetchUsers).toHaveBeenCalledTimes(2)
    expect(fetchUsers.mock.calls[0]![0]).toHaveLength(50)
    expect(fetchUsers.mock.calls[0]![0].slice(0, 3)).toEqual([2n, 3n, 99n])
    expect(cache.get("2")).toEqual({ name: "User 2" })
    expect(cache.get("149")).toEqual({ name: "User 149" })

    await cache.ensureUsers(["2", "99"])
    expect(fetchUsers).toHaveBeenCalledTimes(2)

    now += 11 * 60_000
    await cache.ensureUsers(["99"])
    expect(fetchUsers).toHaveBeenCalledTimes(3)
  })
})
