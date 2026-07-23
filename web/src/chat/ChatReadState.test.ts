import { messageId } from "@inline/ids"
import { afterEach, describe, expect, it, vi } from "vitest"
import {
  ChatReadStateCoordinator,
  isChatDocumentActive,
} from "./ChatReadState"

describe("ChatReadStateCoordinator", () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it("requires a focused visible chat at the bottom", async () => {
    vi.useFakeTimers()
    const send = vi.fn(async () => undefined)
    const coordinator = new ChatReadStateCoordinator({ send })

    coordinator.observe({
      active: false,
      atBottom: true,
      needsRead: true,
      latestMessageId: messageId(1),
    })
    coordinator.observe({
      active: true,
      atBottom: false,
      needsRead: true,
      latestMessageId: messageId(2),
    })
    coordinator.observe({
      active: true,
      atBottom: true,
      needsRead: false,
      latestMessageId: messageId(3),
    })
    await vi.advanceTimersByTimeAsync(500)

    expect(send).not.toHaveBeenCalled()
  })

  it("coalesces rapid renders to the highest exact read boundary", async () => {
    vi.useFakeTimers()
    const send = vi.fn(async () => undefined)
    const coordinator = new ChatReadStateCoordinator({ send })

    for (const id of [10, 30, 20]) {
      coordinator.observe({
        active: true,
        atBottom: true,
        needsRead: true,
        latestMessageId: messageId(id),
      })
    }
    await vi.advanceTimersByTimeAsync(149)
    expect(send).not.toHaveBeenCalled()
    await vi.advanceTimersByTimeAsync(1)

    expect(send).toHaveBeenCalledTimes(1)
    expect(send).toHaveBeenCalledWith(messageId(30))
  })

  it("keeps only the latest boundary behind an in-flight mutation", async () => {
    vi.useFakeTimers()
    let finishFirst: (() => void) | undefined
    const send = vi
      .fn<(maxId: ReturnType<typeof messageId>) => Promise<void>>()
      .mockImplementationOnce(
        () =>
          new Promise<void>((resolve) => {
            finishFirst = resolve
          }),
      )
      .mockResolvedValue(undefined)
    const coordinator = new ChatReadStateCoordinator({ send })
    const observe = (id: number) =>
      coordinator.observe({
        active: true,
        atBottom: true,
        needsRead: true,
        latestMessageId: messageId(id),
      })

    observe(10)
    await vi.advanceTimersByTimeAsync(150)
    observe(20)
    observe(30)
    await vi.advanceTimersByTimeAsync(500)
    expect(send).toHaveBeenCalledTimes(1)

    finishFirst?.()
    await Promise.resolve()
    await vi.advanceTimersByTimeAsync(150)
    expect(send).toHaveBeenCalledTimes(2)
    expect(send).toHaveBeenLastCalledWith(messageId(30))
  })

  it("cancels an unsent observation when the chat unmounts", async () => {
    vi.useFakeTimers()
    const send = vi.fn(async () => undefined)
    const coordinator = new ChatReadStateCoordinator({ send })
    coordinator.observe({
      active: true,
      atBottom: true,
      needsRead: true,
      latestMessageId: messageId(1),
    })
    coordinator.dispose()
    await vi.advanceTimersByTimeAsync(500)
    expect(send).not.toHaveBeenCalled()
  })

  it("restarts after React Strict Mode's lifecycle probe", async () => {
    vi.useFakeTimers()
    const send = vi.fn(async () => undefined)
    const coordinator = new ChatReadStateCoordinator({ send })

    coordinator.activate()
    coordinator.dispose()
    coordinator.activate()
    coordinator.observe({
      active: true,
      atBottom: true,
      needsRead: true,
      latestMessageId: messageId(11),
    })
    await vi.advanceTimersByTimeAsync(150)

    expect(send).toHaveBeenCalledOnce()
    expect(send).toHaveBeenCalledWith(messageId(11))
  })

  it("allows the same read boundary again after a rejected mutation rolls back", async () => {
    vi.useFakeTimers()
    const send = vi
      .fn<(maxId: ReturnType<typeof messageId>) => Promise<void>>()
      .mockRejectedValueOnce(new Error("rejected"))
      .mockResolvedValue(undefined)
    const coordinator = new ChatReadStateCoordinator({
      send,
      onError: vi.fn(),
    })
    const observation = {
      active: true,
      atBottom: true,
      needsRead: true,
      latestMessageId: messageId(10),
    }

    coordinator.observe(observation)
    await vi.advanceTimersByTimeAsync(150)
    coordinator.observe(observation)
    await vi.advanceTimersByTimeAsync(150)

    expect(send).toHaveBeenCalledTimes(2)
    expect(send).toHaveBeenNthCalledWith(1, messageId(10))
    expect(send).toHaveBeenNthCalledWith(2, messageId(10))
  })
})

describe("isChatDocumentActive", () => {
  it("requires both visibility and window focus", () => {
    expect(
      isChatDocumentActive({
        visibilityState: "visible",
        hasFocus: () => true,
      }),
    ).toBe(true)
    expect(
      isChatDocumentActive({
        visibilityState: "visible",
        hasFocus: () => false,
      }),
    ).toBe(false)
    expect(
      isChatDocumentActive({
        visibilityState: "hidden",
        hasFocus: () => true,
      }),
    ).toBe(false)
  })
})
