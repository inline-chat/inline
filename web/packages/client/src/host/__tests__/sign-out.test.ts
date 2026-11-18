import { chatId as makeChatId, type UserID } from "@inline/ids"
import { afterEach, describe, expect, it } from "vitest"
import { testBytes } from "../../media/testing/transfer-server"
import { ERASE_MARKER } from "../erase"
import { MediaModelHost } from "./media-host"
import { self } from "./model-host"

/**
 * Sign-out erases the account's data even when the worker dies right after
 * (a tab closed on "Sign Out"): an erase marker is written first, the erase
 * never waits for the server's logout, `signedOut` follows the erase and
 * says how it ended (`erased`), and an erase cut short is finished by the
 * next start of that account before anything opens the replica.
 */

const chat = makeChatId(10)

const running: MediaModelHost[] = []
afterEach(async () => {
  for (const host of running.splice(0)) await host.dispose()
})

const marker = `accounts/u${self}/${ERASE_MARKER}`

const boot = async () => {
  const mh = new MediaModelHost()
  running.push(mh)
  mh.model.addUser(2n, "Ada")
  mh.model.addChat({ id: 10n, title: "Design", participants: [2n] })
  mh.model.postMessage({ chatId: 10n, fromId: 2n, text: "secret plans" })
  await mh.seedDisk()
  await mh.start()
  mh.ui.subscribeTo(2, { kind: "chatWindow", chatId: chat, anchor: "latest" })
  await mh.until(() => mh.ui.list(2).length === 1, "window")
  // Media on the device: a staged attachment.
  mh.intent("attach", {
    kind: "attachFile",
    attachmentId: "d".repeat(24),
    file: new Blob([testBytes(64, 1) as Uint8Array<ArrayBuffer>], { type: "application/pdf" }),
    fileName: "plans.pdf",
    mimeType: "application/pdf",
  })
  expect((await mh.final("attach")).status).toBe("confirmed")
  expect((await mh.bytes.list(`accounts/u${self}/media/`)).length).toBeGreaterThan(0)
  // Something only this device has: a draft.
  mh.intent("draft", { kind: "saveDraft", chatId: chat, text: "private draft", revision: 1 })
  expect((await mh.final("draft")).status).toBe("confirmed")
  // The server never answers LOG_OUT.
  mh.endpoint.interceptor = (frame) =>
    frame.kind === "result" &&
    frame.message.body.oneofKind === "rpcResult" &&
    frame.message.body.rpcResult.result.oneofKind === "logOut"
      ? "drop"
      : "deliver"
  return mh
}

/** The worker dies: nothing of this host runs on; the disk and byte store stay. */
const kill = (mh: MediaModelHost) => {
  mh.transport.kill()
  mh.endpoint.dispose()
}

const nothingLeft = async (mh: MediaModelHost, options: { synced?: boolean } = {}) => {
  // After a new sign-in the server sends its data again; the device's own never comes back.
  if (!options.synced) {
    expect(await mh.disk.count("message")).toBe(0)
    expect(await mh.disk.count("dialog")).toBe(0)
  }
  expect(await mh.disk.count("message_draft")).toBe(0)
  expect(await mh.bytes.list(`accounts/u${self}/media/`)).toEqual([])
}

describe("sign-out", () => {
  it("erases first, emits signedOut with erased: complete, and the logout never delays it", async () => {
    const mh = await boot()
    const started = mh.time.now()
    mh.ui.post({ kind: "session", action: "signOut" })
    await mh.until(() => mh.ui.core(1)?.phase === "signedOut", "signed out")
    expect(mh.time.now() - started).toBeLessThan(100)
    expect(mh.ui.core(1)).toMatchObject({ phase: "signedOut", erased: "complete" })
    expect(mh.ui.core(1)?.signingOut).toBeUndefined()
    expect(mh.disk.erased).toBe(1)
    expect(await mh.bytes.stat(marker)).toBeUndefined()
    await nothingLeft(mh)
  })

  it("refuses every intent once the sign-out started; nothing is written after the erase begins", async () => {
    const mh = await boot()
    let release: () => void = () => undefined
    // The erase is slow: the sign-out stays in progress.
    mh.storageWrap = (storage) => ({
      ...storage,
      erase: async () => {
        await new Promise<void>((resolve) => {
          release = resolve
        })
        await storage.erase()
      },
    })
    await mh.stop()
    await mh.start()
    mh.ui.post({ kind: "session", action: "signOut" })
    await mh.until(() => mh.ui.core(1)?.signingOut === true, "signing out")
    mh.intent("late-draft", { kind: "saveDraft", chatId: chat, text: "after", revision: 9 })
    mh.intent("late-send", { kind: "sendText", chatId: chat, clientKey: "99", text: "after" })
    expect(await mh.final("late-draft")).toMatchObject({ status: "rejected", reason: "notSignedIn" })
    expect(await mh.final("late-send")).toMatchObject({ status: "rejected", reason: "notSignedIn" })
    expect(await mh.bytes.stat(marker)).toBeDefined()
    release()
    await mh.until(() => mh.ui.core(1)?.phase === "signedOut", "signed out")
    expect(mh.ui.core(1)?.erased).toBe("complete")
    await nothingLeft(mh)
  })

  for (const afterMs of [100, 1_000, 2_900]) {
    it(`a worker killed ${afterMs} ms after signOut, logout hanging: the data is gone or marked, and the next start finishes the erase`, async () => {
      const mh = await boot()
      // The replica erase never ends in this worker: it dies in the middle.
      mh.storageWrap = (storage) => ({ ...storage, erase: () => new Promise<void>(() => undefined) })
      await mh.stop()
      await mh.start()
      mh.ui.post({ kind: "session", action: "signOut" })
      await mh.time.advance(afterMs)
      kill(mh)
      // Gone, or marked for the next start.
      expect(mh.disk.erased > 0 || (await mh.bytes.stat(marker)) != null).toBe(true)

      // The next start of this account: the erase finishes before anything opens.
      mh.storageWrap = undefined
      await mh.start()
      expect(mh.disk.erased).toBe(1)
      expect(await mh.bytes.stat(marker)).toBeUndefined()
      await nothingLeft(mh, { synced: true })
    })
  }

  it("an erase that fails says so (erased: failed), keeps the marker, and the next start finishes it", async () => {
    const mh = await boot()
    let failures = 1
    mh.storageWrap = (storage) => ({
      ...storage,
      erase: async () => {
        if (failures-- > 0) throw new Error("disk busy")
        await storage.erase()
      },
    })
    await mh.stop()
    await mh.start()
    mh.ui.post({ kind: "session", action: "signOut" })
    await mh.until(() => mh.ui.core(1)?.phase === "signedOut", "signed out")
    expect(mh.ui.core(1)?.erased).toBe("failed")
    expect(await mh.bytes.stat(marker)).toBeDefined()
    // A boot sweep (nobody signed in) can finish it too; here the next sign-in does.
    const finished = await mh.host.finishPendingErase(self as UserID)
    expect(finished).toBe(true)
    expect(await mh.bytes.stat(marker)).toBeUndefined()
    await nothingLeft(mh)
  })
})
