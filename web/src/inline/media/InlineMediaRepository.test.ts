import { afterEach, describe, expect, it, vi } from "vitest"
import { InlineMediaRepository } from "./InlineMediaRepository"

describe("InlineMediaRepository", () => {
  afterEach(() => {
    vi.useRealTimers()
    vi.restoreAllMocks()
  })

  it("deduplicates concurrent downloads and revokes the shared object URL after the last release", async () => {
    const source = {
      loadCached: vi.fn(async () => undefined),
      load: vi.fn(async () => ({
        kind: "blob" as const,
        blob: new Blob(["avatar"]),
      })),
    }
    vi.spyOn(URL, "createObjectURL").mockReturnValue("blob:inline-avatar")
    const revoke = vi.spyOn(URL, "revokeObjectURL").mockImplementation(() => {})
    const repository = new InlineMediaRepository(source, {
      retentionMs: 0,
    })

    const [first, second] = await Promise.all([
      repository.acquire("photo-1", "https://cdn.inline.chat/photo-1"),
      repository.acquire("photo-1", "https://cdn.inline.chat/photo-1"),
    ])

    expect(first.url).toBe("blob:inline-avatar")
    expect(second.url).toBe(first.url)
    expect(source.load).toHaveBeenCalledTimes(1)

    first.release()
    expect(revoke).not.toHaveBeenCalled()
    second.release()
    expect(revoke).toHaveBeenCalledWith("blob:inline-avatar")
  })

  it("keeps a bounded warm renderer URL available synchronously across remounts", async () => {
    vi.useFakeTimers()
    const source = {
      loadCached: vi.fn(async () => undefined),
      load: vi.fn(async () => ({
        kind: "blob" as const,
        blob: new Blob(["warm-avatar"]),
      })),
    }
    vi.spyOn(URL, "createObjectURL").mockReturnValue(
      "blob:warm-avatar",
    )
    const revoke = vi
      .spyOn(URL, "revokeObjectURL")
      .mockImplementation(() => {})
    const repository = new InlineMediaRepository(source, {
      retentionMs: 5_000,
      maximumRetainedEntries: 2,
    })

    const first = await repository.acquire(
      "avatar-1",
      "https://cdn.inline.chat/avatar-1",
    )
    first.release()

    expect(
      repository.peek(
        "avatar-1",
        "https://cdn.inline.chat/avatar-1",
      ),
    ).toBe("blob:warm-avatar")
    const second = await repository.acquire(
      "avatar-1",
      "https://cdn.inline.chat/avatar-1",
    )
    expect(source.load).toHaveBeenCalledOnce()
    second.release()

    await vi.advanceTimersByTimeAsync(5_000)
    expect(repository.peek("avatar-1")).toBeUndefined()
    expect(revoke).toHaveBeenCalledOnce()
  })

  it("revokes retained renderer resources on explicit teardown", async () => {
    const source = {
      loadCached: vi.fn(async () => undefined),
      load: vi.fn(async () => ({
        kind: "blob" as const,
        blob: new Blob(["avatar"]),
      })),
    }
    vi.spyOn(URL, "createObjectURL").mockReturnValue("blob:avatar")
    const revoke = vi
      .spyOn(URL, "revokeObjectURL")
      .mockImplementation(() => {})
    const repository = new InlineMediaRepository(source)
    const handle = await repository.acquire(
      "avatar-1",
      "https://cdn.inline.chat/avatar-1",
    )
    handle.release()

    repository.clear()

    expect(revoke).toHaveBeenCalledWith("blob:avatar")
    expect(repository.peek("avatar-1")).toBeUndefined()
  })

  it("creates a renderer-local object URL for owner-provided bytes", async () => {
    const source = {
      loadCached: vi.fn(async () => undefined),
      load: vi.fn(async () => ({
        kind: "blob" as const,
        blob: new Blob(["cached-avatar"]),
      })),
    }
    vi.spyOn(URL, "createObjectURL").mockReturnValue("blob:cached-avatar")
    vi.spyOn(URL, "revokeObjectURL").mockImplementation(() => {})
    const repository = new InlineMediaRepository(source, {
      retentionMs: 0,
    })

    const handle = await repository.acquire("photo-1", "https://cdn.inline.chat/photo-1")

    expect(handle.url).toBe("blob:cached-avatar")
    handle.release()
  })

  it("renders owner-provided remote media without creating an object URL", async () => {
    const remoteUrl =
      "https://440e08ac.example.r2.cloudflarestorage.com/inline/photo?X-Amz-Signature=test"
    const source = {
      loadCached: vi.fn(async () => undefined),
      load: vi.fn(async () => ({
        kind: "remote" as const,
        url: remoteUrl,
      })),
    }
    const createObjectUrl = vi.spyOn(
      URL,
      "createObjectURL",
    )
    const repository = new InlineMediaRepository(source, {
      retentionMs: 0,
    })

    const handle = await repository.acquire("photo-r2", remoteUrl)

    expect(handle.url).toBe(remoteUrl)
    expect(createObjectUrl).not.toHaveBeenCalled()
    handle.release()
  })

  it("promotes persistent bytes into the synchronous renderer hot layer without loading remote media", async () => {
    vi.useFakeTimers()
    const cached = new Blob(["cached-avatar"])
    const source = {
      loadCached: vi.fn(async () => ({
        kind: "blob" as const,
        blob: cached,
      })),
      load: vi.fn(),
    }
    vi.spyOn(URL, "createObjectURL").mockReturnValue(
      "blob:promoted-avatar",
    )
    const revoke = vi
      .spyOn(URL, "revokeObjectURL")
      .mockImplementation(() => {})
    const repository = new InlineMediaRepository(source, {
      retentionMs: 5_000,
    })

    await expect(repository.promoteCached("avatar-1")).resolves.toBe(true)
    expect(repository.peek("avatar-1")).toBe("blob:promoted-avatar")
    expect(source.loadCached).toHaveBeenCalledOnce()
    expect(source.load).not.toHaveBeenCalled()

    const handle = await repository.acquire(
      "avatar-1",
      "https://cdn.inline.chat/avatar-1",
    )
    expect(handle.url).toBe("blob:promoted-avatar")
    expect(source.load).not.toHaveBeenCalled()
    handle.release()

    await vi.advanceTimersByTimeAsync(5_000)
    expect(revoke).toHaveBeenCalledWith("blob:promoted-avatar")
  })
})
