import { chatId, userId } from "@inline/ids"
import { act, renderHook } from "@testing-library/react"
import { StrictMode, type PropsWithChildren } from "react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { useChatHistory } from "./useChatHistory"

const hydrateMessageWindow = vi.fn(async () => 0)
const query = vi.fn(async () => undefined)
const mutate = vi.fn(async () => undefined)
const mutateAccepted = vi.fn(async () => undefined)
const client = {
  db: { hydrateMessageWindow },
  realtime: { query, mutate, mutateAccepted },
}

vi.mock("@inline/client", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@inline/client")>()
  return {
    ...actual,
    useInlineClient: () => client,
  }
})

const peer = { peerKind: "user", peerId: userId(42) } as const

afterEach(() => {
  hydrateMessageWindow.mockReset()
  hydrateMessageWindow.mockResolvedValue(0)
  query.mockReset()
  query.mockResolvedValue(undefined)
  mutate.mockReset()
  mutate.mockResolvedValue(undefined)
  mutateAccepted.mockReset()
  mutateAccepted.mockResolvedValue(undefined)
})

function StrictModeWrapper({ children }: PropsWithChildren) {
  return <StrictMode>{children}</StrictMode>
}

describe("useChatHistory prepared initial state", () => {
  it("preserves the preloaded projection instead of replacing it after mount", async () => {
    const id = chatId(81)
    const hook = renderHook(() =>
      useChatHistory(peer, id, id, { open: true }),
    )

    expect(hook.result.current.initialLoading).toBe(false)
    await act(async () => undefined)

    expect(hydrateMessageWindow).not.toHaveBeenCalled()
    expect(query).not.toHaveBeenCalled()
    expect(mutate).not.toHaveBeenCalled()
    expect(mutateAccepted).not.toHaveBeenCalled()
    expect(hook.result.current.initialLoading).toBe(false)
  })

  it("refreshes an empty prepared projection after the chat surface mounts", async () => {
    const id = chatId(85)
    let finishQuery: (() => void) | undefined
    query.mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          finishQuery = () => resolve(undefined)
        }),
    )
    const hook = renderHook(() =>
      useChatHistory(peer, id, id, { open: true }, true),
    )

    expect(hook.result.current.initialLoading).toBe(true)
    await act(async () => undefined)
    expect(hydrateMessageWindow).not.toHaveBeenCalled()
    expect(query).toHaveBeenCalledOnce()
    expect(hook.result.current.initialLoading).toBe(true)

    await act(async () => finishQuery?.())
    expect(hook.result.current.initialLoading).toBe(false)
  })

  it("keeps the explicit cold path when no prepared window was handed off", async () => {
    const id = chatId(82)
    const hook = renderHook(() =>
      useChatHistory(peer, id, undefined, { open: true }),
    )

    expect(hook.result.current.initialLoading).toBe(true)
    await act(async () => undefined)

    expect(hydrateMessageWindow).toHaveBeenCalledWith(id, { limit: 60 })
    expect(query).toHaveBeenCalledOnce()
    expect(mutate).not.toHaveBeenCalled()
    expect(mutateAccepted).not.toHaveBeenCalled()
    expect(hook.result.current.initialLoading).toBe(false)
  })

  it("finishes one cold load across the Strict Mode effect replay", async () => {
    const id = chatId(86)
    let finishQuery: (() => void) | undefined
    query.mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          finishQuery = () => resolve(undefined)
        }),
    )

    const hook = renderHook(
      () => useChatHistory(peer, id, undefined, { open: true }),
      { wrapper: StrictModeWrapper },
    )

    expect(hook.result.current.initialLoading).toBe(true)
    await act(async () => undefined)
    expect(hydrateMessageWindow).toHaveBeenCalledOnce()
    expect(query).toHaveBeenCalledOnce()
    expect(hook.result.current.initialLoading).toBe(true)

    await act(async () => finishQuery?.())
    expect(hydrateMessageWindow).toHaveBeenCalledOnce()
    expect(query).toHaveBeenCalledOnce()
    expect(hook.result.current.initialLoading).toBe(false)
  })

  it("surfaces persistence failures and removes the loading cover", async () => {
    const id = chatId(87)
    hydrateMessageWindow.mockRejectedValueOnce(
      new Error("cache unavailable"),
    )

    const hook = renderHook(() =>
      useChatHistory(peer, id, undefined, { open: true }),
    )

    expect(hook.result.current.initialLoading).toBe(true)
    await act(async () => undefined)

    expect(hydrateMessageWindow).toHaveBeenCalledOnce()
    expect(query).not.toHaveBeenCalled()
    expect(hook.result.current.initialLoading).toBe(false)
    expect(hook.result.current.error).toBe("cache unavailable")
  })

  it("reopens a persisted local window without repeating server refreshes", async () => {
    const id = chatId(83)
    hydrateMessageWindow.mockResolvedValueOnce(60)

    const hook = renderHook(() =>
      useChatHistory(peer, id, undefined, { open: true }),
    )

    expect(hook.result.current.initialLoading).toBe(true)
    await act(async () => undefined)

    expect(hydrateMessageWindow).toHaveBeenCalledWith(id, { limit: 60 })
    expect(query).not.toHaveBeenCalled()
    expect(mutate).not.toHaveBeenCalled()
    expect(mutateAccepted).not.toHaveBeenCalled()
    expect(hook.result.current.initialLoading).toBe(false)
  })

  it("locally accepts only the missing open and sidebar intents", async () => {
    const id = chatId(84)
    const threadPeer = {
      peerKind: "chat",
      peerId: id,
    } as const

    renderHook(() =>
      useChatHistory(threadPeer, id, id, {
        open: false,
        chatListHidden: true,
      }),
    )
    await act(async () => undefined)

    expect(mutateAccepted).toHaveBeenCalledTimes(2)
    expect(mutate).not.toHaveBeenCalled()
    expect(query).not.toHaveBeenCalled()
  })
})
