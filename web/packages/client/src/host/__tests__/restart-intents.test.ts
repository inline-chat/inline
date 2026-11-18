import { RpcError_Code } from "@inline-chat/protocol/core"
import { newClientKey, type Intent } from "@inline/core-protocol"
import { chatId as makeChatId } from "@inline/ids"
import { afterEach, describe, expect, it } from "vitest"
import { ModelHost } from "./model-host"

/**
 * Intent results across a core restart. A send accepted by an earlier core
 * is in the durable outbox; the next core restores it. A context that
 * re-posts the same `tx` (a worker handoff, a reload of the leader) is
 * answered `accepted` and then the send's real outcome, read from the
 * replica, instead of `accepted` forever.
 */

const running: ModelHost[] = []
afterEach(async () => {
  for (const host of running.splice(0)) await host.dispose()
})

const design = makeChatId(10)

const boot = async () => {
  const mh = new ModelHost()
  running.push(mh)
  mh.model.addUser(2n, "Ada")
  mh.model.addChat({ id: 10n, title: "Design", participants: [2n] })
  mh.model.postMessage({ chatId: 10n, fromId: 2n, text: "hello" })
  await mh.seedDisk()
  return mh
}

/** Accept a send offline in one core, then stop that core. */
const acceptedThenStopped = async (mh: ModelHost, intent: Intent) => {
  await mh.start({ online: false })
  mh.intent("s1", intent)
  await mh.until(() => mh.ui.result("s1")?.status === "accepted", "accepted by the first core")
  await mh.stop()
}

describe("intent results across a restart", () => {
  it("a re-posted send accepted by an earlier core is confirmed once the restored send lands", async () => {
    const mh = await boot()
    const intent: Intent = { kind: "sendText", chatId: design, clientKey: newClientKey(), text: "survives" }
    await acceptedThenStopped(mh, intent)

    await mh.start({ online: false })
    mh.intent("s1", intent)
    await mh.until(() => mh.ui.result("s1") != null, "answered by the next core")
    expect(mh.results("s1")).toEqual(["accepted"])

    mh.ui.post({ kind: "signal", signal: { kind: "online", online: true } })
    expect((await mh.final("s1")).status).toBe("confirmed")
    expect(mh.results("s1")).toEqual(["accepted", "confirmed"])
    expect(mh.model.messagesWithRandomId(BigInt((intent as { clientKey: string }).clientKey))).toHaveLength(1)
  })

  it("reports the server's refusal of a restored send", async () => {
    const mh = await boot()
    const intent: Intent = { kind: "sendText", chatId: design, clientKey: newClientKey(), text: "refused" }
    await acceptedThenStopped(mh, intent)

    mh.fail = (input) => (input.oneofKind === "sendMessage" ? RpcError_Code.PEER_ID_INVALID : undefined)
    await mh.start({ online: false })
    mh.intent("s1", intent)
    await mh.until(() => mh.ui.result("s1") != null, "answered")
    mh.ui.post({ kind: "signal", signal: { kind: "online", online: true } })
    expect(await mh.final("s1")).toMatchObject({ status: "rejected", reason: "server" })
  })

  it("a re-post after the send already landed is confirmed without a second message", async () => {
    const mh = await boot()
    const intent: Intent = { kind: "sendText", chatId: design, clientKey: newClientKey(), text: "landed" }
    await acceptedThenStopped(mh, intent)
    await mh.start()
    await mh.until(
      () => mh.model.chatState(10n).messages.some((message) => message.text === "landed"),
      "restored send landed",
    )
    await mh.synced()
    mh.intent("s1", intent)
    expect((await mh.final("s1")).status).toBe("confirmed")
    expect(
      mh.model.chatState(10n).messages.filter((message) => message.text === "landed"),
    ).toHaveLength(1)
  })
})
