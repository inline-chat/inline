import { Db } from "@inline/client"
import { chatId } from "@inline/ids"
import { describe, expect, it, vi } from "vitest"
import {
  createOwnedFullChatProgressive,
  FullChatProgressiveLeases,
} from "./FullChatProgressiveService"

describe("FullChatProgressiveService", () => {
  it("publishes active chats once and releases only the final lease", async () => {
    const changes: Array<{
      active: readonly string[]
      released: readonly string[]
    }> = []
    const service = new FullChatProgressiveLeases(
      (active, released) => {
        changes.push({ active, released })
      },
    )

    const releaseFirst = service.activateChat(chatId(10))
    const releaseSecond = service.activateChat(chatId(10))
    const releaseOther = service.activateChat(chatId(20))
    releaseFirst()
    releaseFirst()
    releaseSecond()
    releaseOther()
    await Promise.resolve()

    expect(changes).toEqual([
      { active: [chatId(10)], released: [] },
      { active: [chatId(10), chatId(20)], released: [] },
      {
        active: [],
        released: [chatId(10), chatId(20)],
      },
    ])
  })

  it("reclaims an owned database window when its chat becomes inactive", async () => {
    const db = new Db({ autoHydrate: false, persistence: false })
    const releaseWindow = vi.spyOn(
      db,
      "releaseResidentMessageWindow",
    )
    const service = createOwnedFullChatProgressive(db)

    const release = service.activateChat(chatId(42))
    expect(releaseWindow).not.toHaveBeenCalled()
    release()
    await Promise.resolve()
    expect(releaseWindow).toHaveBeenCalledOnce()
    expect(releaseWindow).toHaveBeenCalledWith(chatId(42))
  })

  it("does not release a same-turn React Strict Mode remount", async () => {
    const changes = vi.fn()
    const service = new FullChatProgressiveLeases(changes)

    const firstRelease = service.activateChat(chatId(10))
    firstRelease()
    const secondRelease = service.activateChat(chatId(10))
    await Promise.resolve()

    expect(changes).toHaveBeenCalledOnce()
    expect(changes).toHaveBeenLastCalledWith(
      [chatId(10)],
      [],
    )

    secondRelease()
    await Promise.resolve()
    expect(changes).toHaveBeenLastCalledWith(
      [],
      [chatId(10)],
    )
  })
})
