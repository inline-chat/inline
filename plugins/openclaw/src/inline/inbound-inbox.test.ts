import { mkdtemp, readFile, readdir, rm, stat, writeFile } from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { afterEach, describe, expect, it } from "vitest"
import { InlineInboundInbox } from "./inbound-inbox.js"

const directories: string[] = []
const identity = { baseUrl: "https://api.inline.chat", accountId: "default", botUserId: 777n }
const payload = { chatId: 7n, msg: { id: 10n, fromId: 42n, text: "private request 👋" }, data: new Uint8Array([0, 255]) }
const directory = async () => {
  const dir = await mkdtemp(path.join(os.tmpdir(), "inline-inbox-test-"))
  directories.push(dir)
  return dir
}
afterEach(async () => { await Promise.all(directories.splice(0).map((dir) => rm(dir, { recursive: true, force: true }))) })

describe("Inline durable inbound custody", () => {
  it("restores accepted pending input with exact bigint and byte values after reopening", async () => {
    const dir = await directory()
    const inbox = await InlineInboundInbox.open<typeof payload>(dir, identity)
    expect(await inbox.accept("message:7:10", payload)).toBe(true)
    const reopened = await InlineInboundInbox.open<typeof payload>(dir, identity)
    expect(reopened.entries()).toEqual([{ id: "message:7:10", state: "pending", payload }])
    expect(await reopened.accept("message:7:10", { ...payload, data: new Uint8Array([1]) })).toBe(false)
    expect(reopened.entries()[0]?.payload.data).toEqual(payload.data)
    const files = await readdir(path.join(dir, "channels/inline/inbox"))
    expect((await stat(path.join(dir, "channels/inline/inbox", files[0]!))).mode & 0o777).toBe(0o600)
  })

  it("atomically marks a whole debounced batch uncertain and never makes it pending after restart", async () => {
    const dir = await directory()
    const inbox = await InlineInboundInbox.open<typeof payload>(dir, identity)
    await inbox.accept("a", payload)
    await inbox.accept("b", { ...payload, msg: { ...payload.msg, id: 11n } })
    expect(await inbox.beginDispatch(["a", "b"])).toBe(true)
    const reopened = await InlineInboundInbox.open<typeof payload>(dir, identity)
    expect(reopened.entries().map((entry) => entry.state)).toEqual(["dispatching", "dispatching"])
    expect(await reopened.beginDispatch(["a", "b"])).toBe(false)
    expect(reopened.needsRecoveryNotice("a")).toBe(true)
    await reopened.markRecoveryNotified("a")
    expect((await InlineInboundInbox.open(dir, identity)).needsRecoveryNotice("a")).toBe(false)
  })

  it("retains a dedupe tombstone without message bodies after completion", async () => {
    const dir = await directory()
    const inbox = await InlineInboundInbox.open<typeof payload>(dir, identity)
    await inbox.accept("a", payload)
    await inbox.beginDispatch(["a"])
    await inbox.complete(["a"])
    const reopened = await InlineInboundInbox.open<typeof payload>(dir, identity)
    expect(reopened.entries()).toEqual([])
    expect(await reopened.accept("a", payload)).toBe(false)
    const files = await readdir(path.join(dir, "channels/inline/inbox"))
    expect(await readFile(path.join(dir, "channels/inline/inbox", files[0]!), "utf8")).not.toContain("private request")
  })

  it("keeps the latest voice transcript and cancels pending input before dispatch", async () => {
    const dir = await directory()
    const inbox = await InlineInboundInbox.open<typeof payload>(dir, identity)
    await inbox.accept("voice", payload)
    const transcript = { ...payload, msg: { ...payload.msg, text: "final transcript" } }
    await inbox.updatePending("voice", transcript)
    expect((await InlineInboundInbox.open<typeof payload>(dir, identity)).entries()[0]?.payload).toEqual(transcript)
    await inbox.complete(["voice"])
    expect(await inbox.beginDispatch(["voice"])).toBe(false)
  })

  it("isolates actual bots and endpoints even when the configured account label is reused", async () => {
    const dir = await directory()
    const inbox = await InlineInboundInbox.open<typeof payload>(dir, identity)
    await inbox.accept("a", payload)
    expect((await InlineInboundInbox.open(dir, { ...identity, baseUrl: "https://API.inline.chat/" })).entries()).toHaveLength(1)
    expect((await InlineInboundInbox.open(dir, { ...identity, botUserId: 888n })).entries()).toEqual([])
    expect((await InlineInboundInbox.open(dir, { ...identity, baseUrl: "https://other.inline.test" })).entries()).toEqual([])
  })

  it("cancels an earlier pending voice request even when its transcript is updated after Stop arrives", async () => {
    const dir = await directory()
    const inbox = await InlineInboundInbox.open<typeof payload>(dir, identity)
    await inbox.accept("voice", payload)
    await inbox.accept("stop", payload)
    await inbox.accept("later", payload)
    await inbox.updatePending("voice", { ...payload, msg: { ...payload.msg, text: "final transcript" } })
    const reopened = await InlineInboundInbox.open<typeof payload>(dir, identity)
    expect(reopened.pendingBefore(["stop"]).map((entry) => entry.id)).toEqual(["voice"])
    expect(await reopened.cancelPendingBefore(["stop"], () => true)).toEqual(["voice"])
    expect(reopened.state("later")).toBe("pending")
  })

  it("does not retire a turn that begins dispatch before atomic pending cancellation", async () => {
    const dir = await directory()
    const inbox = await InlineInboundInbox.open<typeof payload>(dir, identity)
    await inbox.accept("voice", payload)
    await inbox.accept("stop", payload)
    const dispatching = inbox.beginDispatch(["voice"])
    const cancelled = inbox.cancelPendingBefore(["stop"], () => true)
    expect(await dispatching).toBe(true)
    expect(await cancelled).toEqual([])
    expect((await InlineInboundInbox.open(dir, identity)).state("voice")).toBe("dispatching")
  })

  it("does not let a cancelled Stop use its newer completion timestamp to cancel later input", async () => {
    const dir = await directory()
    const inbox = await InlineInboundInbox.open<typeof payload>(dir, identity)
    await inbox.accept("earlier", payload)
    await inbox.accept("stop", payload)
    await inbox.accept("later", payload)
    await inbox.complete(["stop"])
    expect(await inbox.cancelPendingBefore(["stop"], () => true)).toEqual([])
    expect(inbox.state("earlier")).toBe("pending")
    expect(inbox.state("later")).toBe("pending")
  })

  it("does not accept input when its durable write fails", async () => {
    const dir = await directory()
    const inbox = await InlineInboundInbox.open<typeof payload>(dir, identity)
    await writeFile(path.join(dir, "channels"), "blocked")
    await expect(inbox.accept("a", payload)).rejects.toThrow()
    expect(inbox.entries()).toEqual([])
    expect(inbox.state("a")).toBeUndefined()
  })

  it("fences late callbacks from a stopped monitor before a replacement opens the same inbox", async () => {
    const dir = await directory()
    const first = await InlineInboundInbox.open<typeof payload>(dir, identity)
    await first.accept("a", payload)
    await first.beginDispatch(["a"])
    await first.close()
    const replacement = await InlineInboundInbox.open<typeof payload>(dir, identity)
    await replacement.accept("b", payload)
    await expect(first.complete(["a"])).rejects.toThrow("closed")
    expect((await InlineInboundInbox.open(dir, identity)).entries().map((entry) => [entry.id, entry.state])).toEqual([
      ["a", "dispatching"], ["b", "pending"],
    ])
  })

  it("bounds one oversized input and the aggregate retained bytes before accepting them", async () => {
    const dir = await directory()
    const inbox = await InlineInboundInbox.open(dir, identity)
    await expect(inbox.accept("oversized", "x".repeat(1024 * 1024 + 1))).rejects.toThrow("byte limit")
    expect(inbox.state("oversized")).toBeUndefined()
    const large = "x".repeat(800_000)
    for (let index = 0; index < 10; index++) await inbox.accept(String(index), large)
    await expect(inbox.accept("over-total", large)).rejects.toThrow("byte limit")
    expect(inbox.state("over-total")).toBeUndefined()
    expect((await InlineInboundInbox.open(dir, identity)).entries()).toHaveLength(10)
  })
})
