import { describe, expect, it, vi } from "vitest"
import { InlineSenderProfileCache } from "./sender-profile-cache.js"

describe("InlineSenderProfileCache", () => {
  it("hydrates participants once and merges partial profiles", async () => {
    const fetchChatParticipants = vi.fn(async () => [
      { id: 42n, firstName: "Ada" },
      { id: 42n, lastName: "Lovelace", username: "@ada" },
    ])
    const fetchDirectoryUsers = vi.fn(async () => [])
    const cache = new InlineSenderProfileCache({ fetchChatParticipants, fetchDirectoryUsers })

    await expect(cache.resolve({ userId: "42", chatId: 7n })).resolves.toEqual({
      name: "Ada Lovelace",
      username: "ada",
    })
    await cache.resolve({ userId: "42", chatId: 7n })

    expect(fetchChatParticipants).toHaveBeenCalledTimes(1)
    expect(fetchDirectoryUsers).not.toHaveBeenCalled()
  })

  it("preserves bot identity across partial profile hydration", async () => {
    const fetchChatParticipants = vi.fn(async () => [
      { id: 42n, firstName: "Research Bot", bot: true },
      { id: 42n, username: "research", bot: undefined },
    ])
    const cache = new InlineSenderProfileCache({
      fetchChatParticipants,
      fetchDirectoryUsers: vi.fn(async () => []),
    })

    await expect(cache.resolve({ userId: "42", chatId: 7n })).resolves.toEqual({
      name: "Research Bot",
      username: "research",
      bot: true,
    })
  })

  it("uses one directory fallback for concurrent participant misses", async () => {
    const fetchChatParticipants = vi.fn(async () => [])
    const fetchDirectoryUsers = vi.fn(async () => [{ id: 42n, firstName: "Ada" }])
    const cache = new InlineSenderProfileCache({ fetchChatParticipants, fetchDirectoryUsers })

    const [first, second] = await Promise.all([
      cache.resolve({ userId: "42", chatId: 7n }),
      cache.resolve({ userId: "42", chatId: 7n }),
    ])

    expect(first).toEqual({ name: "Ada" })
    expect(second).toEqual({ name: "Ada" })
    expect(fetchChatParticipants).toHaveBeenCalledTimes(1)
    expect(fetchDirectoryUsers).toHaveBeenCalledTimes(1)
  })

  it("uses the directory when a participant record has no display identity", async () => {
    const fetchChatParticipants = vi.fn(async () => [{ id: 42n }])
    const fetchDirectoryUsers = vi.fn(async () => [{ id: 42n, firstName: "Ada", username: "ada" }])
    const cache = new InlineSenderProfileCache({ fetchChatParticipants, fetchDirectoryUsers })

    await expect(cache.resolve({ userId: "42", chatId: 7n })).resolves.toEqual({
      name: "Ada",
      username: "ada",
    })
    expect(fetchDirectoryUsers).toHaveBeenCalledTimes(1)
  })

  it("hydrates a new chat even when its current sender is already cached", async () => {
    const fetchChatParticipants = vi.fn(async () => [{ id: 7n, firstName: "Grace" }])
    const fetchDirectoryUsers = vi.fn(async () => [])
    const cache = new InlineSenderProfileCache({ fetchChatParticipants, fetchDirectoryUsers })
    cache.remember([{ id: 42n, firstName: "Ada" }])

    await expect(cache.resolve({ userId: "42", chatId: 7n })).resolves.toEqual({ name: "Ada" })

    expect(fetchChatParticipants).toHaveBeenCalledTimes(1)
    expect(cache.get("7")).toEqual({ name: "Grace" })
    expect(fetchDirectoryUsers).not.toHaveBeenCalled()
  })

  it("expires hydration state and retries failed fetches", async () => {
    let now = 100
    const fetchChatParticipants = vi.fn()
      .mockRejectedValueOnce(new Error("temporary"))
      .mockResolvedValue([{ id: 42n, username: "ada" }])
    const fetchDirectoryUsers = vi.fn(async () => [])
    const onError = vi.fn()
    const cache = new InlineSenderProfileCache({
      fetchChatParticipants,
      fetchDirectoryUsers,
      onError,
      ttlMs: 10,
      now: () => now,
    })

    await expect(cache.resolve({ userId: "42", chatId: 7n })).resolves.toBeUndefined()
    await expect(cache.resolve({ userId: "42", chatId: 7n })).resolves.toEqual({ username: "ada" })
    now = 111
    await expect(cache.resolve({ userId: "42", chatId: 7n })).resolves.toEqual({ username: "ada" })

    expect(fetchChatParticipants).toHaveBeenCalledTimes(3)
    expect(fetchDirectoryUsers).toHaveBeenCalledTimes(1)
    expect(onError).toHaveBeenCalledWith("getChatParticipants", expect.any(Error))
  })

  it("retries a failed directory fallback", async () => {
    const fetchChatParticipants = vi.fn(async () => [])
    const fetchDirectoryUsers = vi.fn()
      .mockRejectedValueOnce(new Error("temporary"))
      .mockResolvedValue([{ id: 42n, firstName: "Ada" }])
    const onError = vi.fn()
    const cache = new InlineSenderProfileCache({ fetchChatParticipants, fetchDirectoryUsers, onError })

    await expect(cache.resolve({ userId: "42", chatId: 7n })).resolves.toBeUndefined()
    await expect(cache.resolve({ userId: "42", chatId: 7n })).resolves.toEqual({ name: "Ada" })

    expect(fetchChatParticipants).toHaveBeenCalledTimes(1)
    expect(fetchDirectoryUsers).toHaveBeenCalledTimes(2)
    expect(onError).toHaveBeenCalledWith("getChats", expect.any(Error))
  })

  it("marks sender provenance unverified when both hydration paths fail", async () => {
    const cache = new InlineSenderProfileCache({
      fetchChatParticipants: vi.fn(async () => { throw new Error("participants unavailable") }),
      fetchDirectoryUsers: vi.fn(async () => { throw new Error("directory unavailable") }),
    })

    await expect(cache.resolveWithProvenance({ userId: "42", chatId: 7n })).resolves.toEqual({
      provenanceVerified: false,
    })
  })

  it("bounds profiles and makes evicted users immediately fetchable", async () => {
    const fetchChatParticipants = vi.fn(async () => [{ id: 1n, firstName: "One" }])
    const fetchDirectoryUsers = vi.fn(async () => [])
    const cache = new InlineSenderProfileCache({ fetchChatParticipants, fetchDirectoryUsers, maxProfiles: 2 })

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
    const fetchDirectoryUsers = vi.fn(async () => [])
    const cache = new InlineSenderProfileCache({ fetchChatParticipants, fetchDirectoryUsers, maxProfiles: 2 })

    await cache.hydrateChat(1n)
    await cache.hydrateChat(2n)
    await cache.hydrateChat(3n)
    await cache.hydrateChat(1n)

    expect(fetchChatParticipants).toHaveBeenCalledTimes(4)
  })
})
