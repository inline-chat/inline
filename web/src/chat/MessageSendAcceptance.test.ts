import { Db, DbObjectKind, messageKey } from "@inline/client/core"
import { chatId, messageId, userId } from "@inline/ids"
import { describe, expect, it, vi } from "vitest"
import { waitForMessageSendAcceptance } from "./MessageSendAcceptance"

const targetChatId = chatId(10)
const temporaryMessageId = messageId(90)

describe("waitForMessageSendAcceptance", () => {
  it("waits for the owner-projected optimistic message, not the network result", async () => {
    const db = new Db({ autoHydrate: false, persistence: false })
    let resolveNetwork!: () => void
    const network = new Promise<void>((resolve) => {
      resolveNetwork = resolve
    })
    const accepted = waitForMessageSendAcceptance(
      db,
      targetChatId,
      temporaryMessageId,
      network,
    )
    const resolved = vi.fn()
    void accepted.then(resolved)
    await Promise.resolve()
    expect(resolved).not.toHaveBeenCalled()

    db.insert({
      kind: DbObjectKind.Message,
      id: messageKey(targetChatId, temporaryMessageId),
      chatId: targetChatId,
      messageId: temporaryMessageId,
      fromId: userId(7),
      out: true,
      message: "Queued offline",
    })
    await expect(accepted).resolves.toBeUndefined()
    expect(resolved).toHaveBeenCalledOnce()
    resolveNetwork()
  })

  it("rejects when local acceptance fails before a message is projected", async () => {
    const db = new Db({ autoHydrate: false, persistence: false })
    const failure = new Error("owner rejected local commit")
    await expect(
      waitForMessageSendAcceptance(
        db,
        targetChatId,
        temporaryMessageId,
        Promise.reject(failure),
      ),
    ).rejects.toBe(failure)
  })

  it("accepts an already projected optimistic message immediately", async () => {
    const db = new Db({ autoHydrate: false, persistence: false })
    db.insert({
      kind: DbObjectKind.Message,
      id: messageKey(targetChatId, temporaryMessageId),
      chatId: targetChatId,
      messageId: temporaryMessageId,
      fromId: userId(7),
      out: true,
      message: "Already accepted",
    })
    await expect(
      waitForMessageSendAcceptance(
        db,
        targetChatId,
        temporaryMessageId,
        new Promise(() => undefined),
      ),
    ).resolves.toBeUndefined()
  })
})
