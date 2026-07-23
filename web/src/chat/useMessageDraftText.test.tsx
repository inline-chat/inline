import { userId } from "@inline/ids"
import { act, renderHook } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import type { ReactNode } from "react"
import type {
  MessageDraft,
  MessageDraftPeer,
} from "@inline/client/core"
import {
  DbObjectKind,
  messageDraftKey,
} from "@inline/client/core"
import {
  InlineMessageDraftsProvider,
} from "../inline/drafts/InlineMessageDraftsContext"
import type {
  InlineMessageDraftsService,
} from "../inline/drafts/InlineMessageDrafts"
import { useMessageDraftText } from "./useMessageDraftText"
import { InlineCoreProtocolError } from "../inline/core/InlineCoreRendererClient"

const routePeer = {
  peerKind: "user" as const,
  peerId: userId(42),
}

const storedDraft = (text: string): MessageDraft => ({
  kind: DbObjectKind.MessageDraft,
  id: messageDraftKey({
    peerKind: "user",
    peerUserId: userId(42),
  }),
  peerKind: "user",
  peerUserId: userId(42),
  text,
  revision: 1,
  updatedAt: 1,
})

const deferred = <T,>() => {
  let resolve!: (value: T) => void
  const promise = new Promise<T>((next) => {
    resolve = next
  })
  return { promise, resolve }
}

const renderDraft = (drafts: InlineMessageDraftsService) =>
  renderHook(() => useMessageDraftText(routePeer), {
    wrapper: ({ children }: { children: ReactNode }) => (
      <InlineMessageDraftsProvider drafts={drafts}>
        {children}
      </InlineMessageDraftsProvider>
    ),
  })

describe("useMessageDraftText", () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it("restores the peer draft without loading all drafts", async () => {
    const load = vi.fn(
      async (_peer: MessageDraftPeer) => storedDraft("restored"),
    )
    const drafts: InlineMessageDraftsService = {
      load,
      update: vi.fn(async () => undefined),
      clear: vi.fn(async () => undefined),
    }
    const hook = renderDraft(drafts)

    await act(async () => undefined)

    expect(hook.result.current.text).toBe("restored")
    expect(load).toHaveBeenCalledWith({
      peerKind: "user",
      peerUserId: userId(42),
    })
  })

  it("never overwrites typing with a late restoration", async () => {
    const pending = deferred<MessageDraft | undefined>()
    const drafts: InlineMessageDraftsService = {
      load: vi.fn(() => pending.promise),
      update: vi.fn(async () => undefined),
      clear: vi.fn(async () => undefined),
    }
    const hook = renderDraft(drafts)

    act(() => hook.result.current.setText("new text"))
    await act(async () => pending.resolve(storedDraft("old text")))

    expect(hook.result.current.text).toBe("new text")
  })

  it("debounces text persistence and flushes pending text on teardown", async () => {
    vi.useFakeTimers()
    const update = vi.fn(async () => undefined)
    const drafts: InlineMessageDraftsService = {
      load: vi.fn(async () => undefined),
      update,
      clear: vi.fn(async () => undefined),
    }
    const hook = renderDraft(drafts)
    await act(async () => undefined)

    act(() => hook.result.current.setText("one"))
    act(() => hook.result.current.setText("two"))
    await act(async () => vi.advanceTimersByTime(299))
    expect(update).not.toHaveBeenCalled()

    hook.unmount()
    expect(update).toHaveBeenCalledTimes(1)
    expect(update).toHaveBeenCalledWith(
      { peerKind: "user", peerUserId: userId(42) },
      "two",
      undefined,
    )
  })

  it("hands dirty text to a replacement core without logging the retired owner", async () => {
    vi.useFakeTimers()
    const consoleError = vi
      .spyOn(console, "error")
      .mockImplementation(() => undefined)
    const retiredUpdate = vi.fn(async () => {
      throw new InlineCoreProtocolError(
        "Inline core worker stopped responding",
        "owner-failed",
      )
    })
    const replacementUpdate = vi.fn(async () => undefined)
    const retired: InlineMessageDraftsService = {
      load: vi.fn(async () => undefined),
      update: retiredUpdate,
      clear: vi.fn(async () => undefined),
    }
    const replacement: InlineMessageDraftsService = {
      load: vi.fn(async () => undefined),
      update: replacementUpdate,
      clear: vi.fn(async () => undefined),
    }
    let activeDrafts = retired
    const hook = renderHook(() => useMessageDraftText(routePeer), {
      wrapper: ({ children }: { children: ReactNode }) => (
        <InlineMessageDraftsProvider drafts={activeDrafts}>
          {children}
        </InlineMessageDraftsProvider>
      ),
    })
    await act(async () => undefined)

    act(() => hook.result.current.setText("survives recovery"))
    activeDrafts = replacement
    hook.rerender()
    await act(async () => undefined)

    expect(retiredUpdate).toHaveBeenCalledWith(
      { peerKind: "user", peerUserId: userId(42) },
      "survives recovery",
      undefined,
    )
    expect(replacementUpdate).toHaveBeenCalledWith(
      { peerKind: "user", peerUserId: userId(42) },
      "survives recovery",
      undefined,
    )
    expect(consoleError).not.toHaveBeenCalled()
    consoleError.mockRestore()
  })

  it("suppresses a late restoration after an explicit clear", async () => {
    const pending = deferred<MessageDraft | undefined>()
    const clear = vi.fn(async () => undefined)
    const drafts: InlineMessageDraftsService = {
      load: vi.fn(() => pending.promise),
      update: vi.fn(async () => undefined),
      clear,
    }
    const hook = renderDraft(drafts)

    await act(async () => hook.result.current.clear())
    await act(async () => pending.resolve(storedDraft("stale")))

    expect(hook.result.current.text).toBe("")
    expect(clear).toHaveBeenCalledOnce()
  })

  it("clears an accepted send only when no newer typing replaced it", async () => {
    const clear = vi.fn(async () => undefined)
    const drafts: InlineMessageDraftsService = {
      load: vi.fn(async () => undefined),
      update: vi.fn(async () => undefined),
      clear,
    }
    const hook = renderDraft(drafts)
    await act(async () => undefined)

    act(() => hook.result.current.setText("submitted"))
    const submittedRevision = hook.result.current.revision
    act(() => hook.result.current.setText("newer typing"))
    await expect(
      hook.result.current.clearIfUnchanged(submittedRevision),
    ).resolves.toBe(false)
    expect(hook.result.current.text).toBe("newer typing")
    expect(clear).not.toHaveBeenCalled()

    await act(async () => {
      await expect(
        hook.result.current.clearIfUnchanged(
          hook.result.current.revision,
        ),
      ).resolves.toBe(true)
    })
    expect(hook.result.current.text).toBe("")
    expect(clear).toHaveBeenCalledOnce()
  })
})
