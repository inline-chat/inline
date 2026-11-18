import { ConnectionError_Reason, RpcError_Code, type RpcCall } from "@inline-chat/protocol/core"
import type { MessageRow } from "@inline/core-protocol"
import { chatId as makeChatId } from "@inline/ids"
import { afterEach, describe, expect, it } from "vitest"
import { ModelHost } from "./model-host"

/**
 * Sync health in the `core` resource (stalled buckets and `retrySync`), and
 * sign-out telling the server (`LOG_OUT`) online, offline, and against a
 * server that does not answer; never after a revocation.
 */

const running: ModelHost[] = []
afterEach(async () => {
  for (const host of running.splice(0)) await host.dispose()
})

const design = makeChatId(10)

const boot = async (options: ConstructorParameters<typeof ModelHost>[0] = {}) => {
  const mh = new ModelHost(options)
  running.push(mh)
  mh.model.addUser(2n, "Ada")
  mh.model.addChat({ id: 10n, title: "Design", participants: [2n] })
  mh.model.postMessage({ chatId: 10n, fromId: 2n, text: "hello" })
  await mh.seedDisk()
  await mh.start()
  return mh
}

const failsChatBucket = (input: RpcCall["input"]) =>
  input.oneofKind === "getUpdates" &&
  input.getUpdates.bucket?.type.oneofKind === "chat" &&
  input.getUpdates.bucket.type.chat.peerId?.type.oneofKind === "chat" &&
  input.getUpdates.bucket.type.chat.peerId.type.chat.chatId === 10n
    ? RpcError_Code.INTERNAL_ERROR
    : undefined

/** Make chat 10's bucket fail until it stalls. */
const stall = async (mh: ModelHost) => {
  mh.fail = failsChatBucket
  mh.ui.post({ kind: "signal", signal: { kind: "online", online: false } })
  await mh.until(() => mh.ui.core(1)?.connection === "waitingForNetwork", "offline")
  mh.model.postMessage({ chatId: 10n, fromId: 2n, text: "missed" })
  mh.ui.post({ kind: "signal", signal: { kind: "online", online: true } })
  await mh.until(() => mh.ui.core(1)?.stalledSync != null, "stalled", 10 * 60_000)
}

const windowTexts = (mh: ModelHost) => (mh.ui.rows(2) as MessageRow[]).map((row) => row.text)

describe("sync health", () => {
  it("reports a stalled chat bucket in the core resource and clears it after retrySync", async () => {
    const mh = await boot()
    expect(mh.ui.core(1)?.stalledSync).toBeUndefined()
    await stall(mh)
    expect(mh.ui.core(1)?.stalledSync).toEqual([
      { scope: "chat", chatId: design, reason: "retryLimit" },
    ])
    expect(mh.ui.core(1)?.connection).toBe("connected")

    mh.fail = undefined
    mh.intent("retry", { kind: "retrySync" })
    expect((await mh.final("retry")).status).toBe("confirmed")
    await mh.until(() => mh.ui.core(1)?.stalledSync === undefined, "cleared")
    mh.ui.subscribeTo(2, { kind: "chatWindow", chatId: design, anchor: "latest" })
    await mh.until(() => windowTexts(mh).includes("missed"), "caught up")
  })

  it("clears stalls when a new connection opens", async () => {
    const mh = await boot()
    await stall(mh)
    mh.fail = undefined
    await mh.settleUntil(mh.transport.disconnect("network blip"))
    await mh.until(() => mh.ui.core(1)?.stalledSync === undefined, "cleared by reconnect", 60_000)
    expect(mh.ui.core(1)?.connection).toBe("connected")
  })
})

describe("sign-out", () => {
  const logOuts = (mh: ModelHost) => mh.extraRpcs.filter((rpc) => rpc.input.oneofKind === "logOut").length

  it("tells the server, then stops and erases the replica", async () => {
    const mh = await boot()
    mh.ui.post({ kind: "session", action: "signOut" })
    await mh.until(() => mh.ui.core(1)?.phase === "signedOut", "signed out")
    expect(logOuts(mh)).toBe(1)
    expect(mh.ui.core(1)?.connection).toBe("idle")
    expect(mh.disk.erased).toBe(1)
  })

  it("offline, completes locally at once without the server", async () => {
    const mh = await boot()
    mh.ui.post({ kind: "signal", signal: { kind: "online", online: false } })
    await mh.until(() => mh.ui.core(1)?.connection === "waitingForNetwork", "offline")
    const started = mh.time.now()
    mh.ui.post({ kind: "session", action: "signOut" })
    await mh.until(() => mh.ui.core(1)?.phase === "signedOut", "signed out")
    expect(mh.time.now() - started).toBeLessThan(1_000)
    expect(logOuts(mh)).toBe(0)
    expect(mh.disk.erased).toBe(1)
  })

  it("against a server that does not answer, erases at once: the logout never delays the erase", async () => {
    const mh = await boot({ host: { logOutTimeoutMs: 2_000 } })
    mh.endpoint.interceptor = (frame) =>
      frame.kind === "result" &&
      frame.message.body.oneofKind === "rpcResult" &&
      frame.message.body.rpcResult.result.oneofKind === "logOut"
        ? "drop"
        : "deliver"
    const started = mh.time.now()
    mh.ui.post({ kind: "session", action: "signOut" })
    await mh.until(() => mh.ui.core(1)?.phase === "signedOut", "signed out")
    // This used to wait for the answer (up to the timeout) before erasing, so
    // a tab closed during that wait left the replica on disk.
    expect(mh.time.now() - started).toBeLessThan(1_000)
    expect(mh.ui.core(1)?.erased).toBe("complete")
    expect(logOuts(mh)).toBe(1)
    expect(mh.disk.erased).toBe(1)
  })

  it("never calls LOG_OUT when the server revoked the session", async () => {
    const mh = await boot()
    mh.endpoint.rejectWith = ConnectionError_Reason.SESSION_REVOKED
    await mh.settleUntil(mh.transport.disconnect("revoked"))
    await mh.until(() => mh.ui.core(1)?.connection === "sessionRevoked", "revoked")
    expect(mh.ui.core(1)?.phase).toBe("signedOut")
    expect(logOuts(mh)).toBe(0)
    expect(mh.disk.erased).toBe(1)
  })
})
