import { describe, expect, it, vi } from "vitest"
import type { CacheSnapshot, VirtualizerHandle } from "virtua"
import {
  MessageListScrollStateStore,
  captureMessageListScrollState,
  classifyMessageListDataChange,
  isMessageListAtBottom,
  messageListChangeShiftsStart,
  restoreMessageListScrollState,
} from "./MessageListScrollState"

const cache = [[40, 42, 44], 42] as unknown as CacheSnapshot
const layoutSignature = "bubble:large:1200x800:2"

describe("MessageListScrollState", () => {
  it("classifies only the render that actually prepends as shift", () => {
    expect(classifyMessageListDataChange([], ["3", "4"])).toBe(
      "initial",
    )
    expect(
      classifyMessageListDataChange(["3", "4"], ["3", "4"]),
    ).toBe("stable")
    expect(
      classifyMessageListDataChange(
        ["3", "4"],
        ["1", "2", "3", "4"],
      ),
    ).toBe("prepend")
    expect(
      classifyMessageListDataChange(
        ["1", "2"],
        ["1", "2", "3", "4"],
      ),
    ).toBe("append")
    expect(
      classifyMessageListDataChange(["1", "2"], ["1", "9"]),
    ).toBe("replace")
  })

  it("classifies bounded-window compaction so Virtua preserves the shared anchor", () => {
    expect(
      classifyMessageListDataChange(
        ["1", "2", "3", "4"],
        ["2", "3", "4"],
      ),
    ).toBe("trim-start")
    expect(
      classifyMessageListDataChange(
        ["1", "2", "3", "4"],
        ["1", "2", "3"],
      ),
    ).toBe("trim-end")
    expect(
      classifyMessageListDataChange(
        ["1", "2", "3", "4"],
        ["3", "4", "5", "6"],
      ),
    ).toBe("window-forward")
    expect(
      classifyMessageListDataChange(
        ["3", "4", "5", "6"],
        ["1", "2", "3", "4"],
      ),
    ).toBe("window-backward")

    expect(messageListChangeShiftsStart("trim-start")).toBe(true)
    expect(messageListChangeShiftsStart("window-forward")).toBe(false)
    expect(messageListChangeShiftsStart("window-backward")).toBe(false)
    expect(messageListChangeShiftsStart("trim-end")).toBe(false)
    expect(messageListChangeShiftsStart("append")).toBe(false)
  })

  it("uses a tolerant distance-to-bottom boundary", () => {
    expect(isMessageListAtBottom(1_000, 568, 400)).toBe(true)
    expect(isMessageListAtBottom(1_000, 567, 400)).toBe(false)
    expect(isMessageListAtBottom(1_000, 575, 400, 25)).toBe(true)
  })

  it("restores exact cache when identities match and anchors when they changed", () => {
    const handle = {
      cache,
      scrollOffset: 120,
      findItemIndex: vi.fn(() => 1),
      getItemOffset: vi.fn(() => 100),
    } as unknown as VirtualizerHandle
    const state = captureMessageListScrollState(
      handle,
      ["10", "11", "12"],
      false,
      layoutSignature,
    )

    expect(state).toEqual({
      atBottom: false,
      cache,
      scrollOffset: 120,
      anchorId: "11",
      anchorOffset: 20,
      itemIds: ["10", "11", "12"],
      layoutSignature,
    })
    expect(
      restoreMessageListScrollState(
        state,
        ["10", "11", "12"],
        layoutSignature,
      ),
    ).toEqual({
      mode: "exact",
      cache,
      scrollOffset: 120,
      index: 1,
      offset: 20,
    })
    expect(
      restoreMessageListScrollState(
        state,
        ["8", "9", "10", "11", "12"],
        layoutSignature,
      ),
    ).toEqual({ mode: "anchor", index: 3, offset: 20 })
    expect(
      restoreMessageListScrollState(
        state,
        ["20", "21"],
        layoutSignature,
      ),
    ).toEqual({ mode: "bottom" })
  })

  it("restores measured bottom geometry only while message identities still match", () => {
    const state = {
      atBottom: true,
      cache,
      scrollOffset: 120,
      anchorId: "11",
      anchorOffset: 20,
      itemIds: ["10", "11"],
      layoutSignature,
    }
    expect(
      restoreMessageListScrollState(
        state,
        ["10", "11"],
        layoutSignature,
      ),
    ).toEqual({ mode: "bottom", cache, scrollOffset: 120 })
    expect(
      restoreMessageListScrollState(
        state,
        ["10", "11", "12"],
        layoutSignature,
      ),
    ).toEqual({ mode: "bottom" })
    expect(
      restoreMessageListScrollState(
        state,
        ["10", "11"],
        "minimal:large:1200x800:2",
      ),
    ).toEqual({ mode: "bottom" })
  })

  it("bounds peer-scoped state with least-recently-used eviction", () => {
    const store = new MessageListScrollStateStore(2)
    const state = {
      atBottom: true,
      cache,
      scrollOffset: 0,
      anchorOffset: 0,
      itemIds: [] as string[],
      layoutSignature,
    }
    store.set("a", state)
    store.set("b", state)
    expect(store.get("a")).toBe(state)
    store.set("c", state)
    expect(store.get("b")).toBeUndefined()
    expect(store.get("a")).toBe(state)
    expect(store.get("c")).toBe(state)
  })

  it("rehydrates valid bounded geometry and ignores corrupt persisted entries", () => {
    const values = new Map<string, string>()
    const storage = {
      getItem: (key: string) => values.get(key) ?? null,
      setItem: (key: string, value: string) => {
        values.set(key, value)
      },
      removeItem: (key: string) => {
        values.delete(key)
      },
    }
    const state = {
      atBottom: true,
      cache,
      scrollOffset: 120,
      anchorId: "11",
      anchorOffset: 20,
      itemIds: ["10", "11"],
      layoutSignature,
    }
    const first = new MessageListScrollStateStore(2, storage)
    first.set("account:chat", state)

    const restored = new MessageListScrollStateStore(2, storage)
    expect(restored.get("account:chat")).toEqual(state)

    storage.setItem(
      "inline-web-message-list-layout-v1-virtua-0.49",
      JSON.stringify({ entries: [["broken", { cache: "nope" }]] }),
    )
    expect(
      new MessageListScrollStateStore(2, storage).get("broken"),
    ).toBeUndefined()
  })
})
