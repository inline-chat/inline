import { Method, type CreateUploadInput } from "@inline-chat/protocol/core"
import {
  mediaSendIntents,
  newClientKey,
  rowKey,
  sentMessageRowId,
  type AttachmentId,
  type DraftRow,
  type MessageRow,
} from "@inline/core-protocol"
import { chatId as makeChatId } from "@inline/ids"
import { afterEach, describe, expect, it } from "vitest"
import { testBytes } from "../../media/testing/transfer-server"
import { MediaModelHost } from "./media-host"
import { ModelHost } from "./model-host"

/**
 * What a send carries beyond its message (contract-2):
 * - the draft it consumes, deleted in the send's own commit;
 * - the UI's transaction ID on the sending row (`MessageRow.tx`), kept
 *   durably across a restart while the send is in the outbox;
 * - a sending video's size, length and poster frame, which the upload hands
 *   the server so the sent message keeps that size.
 */

const chat = makeChatId(10)

const running: ModelHost[] = []
afterEach(async () => {
  for (const host of running.splice(0)) await host.dispose()
})

const boot = async <T extends ModelHost>(make: () => T, options: { online?: boolean } = {}): Promise<T> => {
  const mh = make()
  running.push(mh)
  mh.model.addUser(2n, "Ada")
  mh.model.addChat({ id: 10n, title: "Design", participants: [2n] })
  mh.model.postMessage({ chatId: 10n, fromId: 2n, text: "hello" })
  await mh.seedDisk()
  await mh.start(options)
  subscribe(mh)
  await mh.until(() => mh.ui.list(2).length === 1, "window")
  return mh
}

const subscribe = (mh: ModelHost) => {
  mh.ui.subscribeTo(2, { kind: "chatWindow", chatId: chat, anchor: "latest" })
  mh.ui.subscribeTo(3, { kind: "draft", chatId: chat })
}

const draft = (mh: ModelHost) => mh.ui.rows(3)[0] as DraftRow | undefined
const sent = (mh: ModelHost, clientKey: string) =>
  mh.ui.state.rows.get(rowKey("message", sentMessageRowId(chat, clientKey))) as MessageRow | undefined

const saveDraft = async (mh: ModelHost, text: string, revision: number) => {
  mh.intent(`draft-${revision}`, { kind: "saveDraft", chatId: chat, text, revision })
  await mh.final(`draft-${revision}`)
  await mh.until(() => draft(mh)?.revision === revision, "draft shown")
}

describe("sendText consumes its draft", () => {
  it("deletes the draft in the send's commit: durable together, and a failed commit keeps both as they were", async () => {
    const mh = await boot(() => new ModelHost())
    await saveDraft(mh, "ship it", 3)
    const messages = await mh.disk.count("message")
    // The commit that would hold the send and the draft's deletion fails.
    mh.disk.failNextWrite = Object.assign(new Error("full"), { name: "QuotaExceededError" })
    mh.intent("full", { kind: "sendText", chatId: chat, clientKey: newClientKey(), text: "ship it", draftRevision: 3 })
    expect(await mh.final("full")).toMatchObject({ status: "rejected", reason: "storageFull" })
    await mh.synced()
    expect(draft(mh)?.text).toBe("ship it")
    expect(await mh.disk.count("message_draft")).toBe(1)
    expect(await mh.disk.count("message")).toBe(messages)

    const clientKey = newClientKey()
    mh.intent("send", { kind: "sendText", chatId: chat, clientKey, text: "ship it", draftRevision: 3 })
    await mh.until(() => mh.ui.result("send", "accepted") != null, "accepted")
    // Accepted: the send and the draft's deletion are on disk together.
    expect(await mh.disk.count("message_draft")).toBe(0)
    expect(await mh.disk.count("message")).toBe(messages + 1)
    expect(mh.ui.result("send", "accepted")?.rows).toContain(rowKey("draft", chat))
    await mh.until(() => draft(mh) == null, "draft gone")
    expect((await mh.final("send")).status).toBe("confirmed")
  })

  it("keeps a draft typed after the send (a higher revision)", async () => {
    const mh = await boot(() => new ModelHost())
    await saveDraft(mh, "next thought", 5)
    mh.intent("send", { kind: "sendText", chatId: chat, clientKey: newClientKey(), text: "first", draftRevision: 4 })
    expect((await mh.final("send")).status).toBe("confirmed")
    expect(draft(mh)?.text).toBe("next thought")
  })

  it("a crash after the commit leaves the draft consumed and the send in the outbox", async () => {
    const mh = await boot(() => new ModelHost(), { online: false })
    await saveDraft(mh, "offline words", 2)
    const clientKey = newClientKey()
    mh.intent("send", { kind: "sendText", chatId: chat, clientKey, text: "offline words", draftRevision: 2 })
    await mh.until(() => mh.ui.result("send", "accepted") != null, "accepted")
    await mh.stop()
    expect(await mh.disk.count("message_draft")).toBe(0)
    await mh.start()
    subscribe(mh)
    await mh.until(() => sent(mh, clientKey)?.state === "sent", "sent by the next core")
    expect(draft(mh)).toBeUndefined()
    expect(mh.model.messagesWithRandomId(BigInt(clientKey))).toHaveLength(1)
  })
})

describe("MessageRow.tx", () => {
  it("names the intent while the send is in the outbox, across a restart, and goes once it lands", async () => {
    const mh = await boot(() => new ModelHost(), { online: false })
    const clientKey = newClientKey()
    mh.intent("tx-send", { kind: "sendText", chatId: chat, clientKey, text: "later" })
    await mh.until(() => sent(mh, clientKey) != null, "sending row")
    expect(sent(mh, clientKey)).toMatchObject({ state: "sending", tx: "tx-send" })
    // A reload or a handoff: a new core, a new UI context, the same disk.
    await mh.stop()
    await mh.start({ online: false })
    subscribe(mh)
    await mh.until(() => sent(mh, clientKey) != null, "restored row")
    expect(sent(mh, clientKey)).toMatchObject({ state: "sending", tx: "tx-send" })
    mh.ui.post({ kind: "signal", signal: { kind: "online", online: true } })
    await mh.until(() => sent(mh, clientKey)?.state === "sent", "sent")
    expect(sent(mh, clientKey)?.tx).toBeUndefined()
    await mh.synced()
    expect(await mh.disk.count("pending_transaction")).toBe(0)
  })

  it("names a media send's intent too", async () => {
    const mh = await boot(() => new MediaModelHost())
    const id = "a".repeat(24) as AttachmentId
    mh.intent("attach", {
      kind: "attachFile",
      attachmentId: id,
      file: new Blob([testBytes(64, 1) as Uint8Array<ArrayBuffer>], { type: "application/pdf" }),
      fileName: "notes.pdf",
      mimeType: "application/pdf",
    })
    expect((await mh.final("attach")).status).toBe("confirmed")
    const clientKey = newClientKey()
    mh.transport.hold()
    mh.intent("media", mediaSendIntents({ chatId: chat, attachments: [{ attachmentId: id, clientKey }] })[0]!)
    await mh.until(() => sent(mh, clientKey) != null, "sending row")
    expect(sent(mh, clientKey)).toMatchObject({ state: "sending", tx: "media" })
    await mh.settleUntil(mh.transport.release())
  })
})

describe("sendMedia", () => {
  it("consumes the draft in the send's commit", async () => {
    const mh = await boot(() => new MediaModelHost())
    await saveDraft(mh, "caption", 7)
    const id = "b".repeat(24) as AttachmentId
    mh.intent("attach", {
      kind: "attachFile",
      attachmentId: id,
      file: new Blob([testBytes(64, 2) as Uint8Array<ArrayBuffer>], { type: "application/pdf" }),
      fileName: "notes.pdf",
      mimeType: "application/pdf",
    })
    expect((await mh.final("attach")).status).toBe("confirmed")
    const clientKey = newClientKey()
    const [intent] = mediaSendIntents({
      chatId: chat,
      text: "caption",
      draftRevision: 7,
      attachments: [{ attachmentId: id, clientKey }],
    })
    expect(intent?.draftRevision).toBe(7)
    mh.intent("media", intent!)
    await mh.until(() => mh.ui.result("media", "accepted") != null, "accepted")
    expect(draft(mh)).toBeUndefined()
    expect(await mh.disk.count("message_draft")).toBe(0)
    expect((await mh.final("media")).status).toBe("confirmed")
  })

  it("a sending video has its size, length and poster frame, and the upload tells the server", async () => {
    const mh = await boot(() => new MediaModelHost())
    const id = "c".repeat(24) as AttachmentId
    const poster = new Uint8Array([0xff, 0xd8, 0xff, 0xd9])
    mh.intent("attach", {
      kind: "attachFile",
      attachmentId: id,
      file: new Blob([testBytes(256, 3) as Uint8Array<ArrayBuffer>], { type: "video/mp4" }),
      fileName: "clip.mp4",
      mimeType: "video/mp4",
      width: 1280,
      height: 720,
      duration: 12,
      preview: poster,
    })
    expect((await mh.final("attach")).status).toBe("confirmed")
    const clientKey = newClientKey()
    mh.transport.hold()
    mh.intent("media", mediaSendIntents({ chatId: chat, attachments: [{ attachmentId: id, clientKey }] })[0]!)
    await mh.until(() => sent(mh, clientKey) != null, "sending row")
    const video = sent(mh, clientKey)!.media
    expect(video).toEqual({
      kind: "video",
      video: { id: "0", width: 1280, height: 720, duration: 12, size: 256, thumbnail: { id: "0", sizes: [], preview: poster } },
    })
    await mh.settleUntil(mh.transport.release())
    await mh.until(() => mh.transfers.callsOf(Method.CREATE_UPLOAD).length > 0, "upload created")
    const create = mh.transfers.callsOf(Method.CREATE_UPLOAD)[0]
    const input = (create?.oneofKind === "createUpload" ? create.createUpload : undefined) as CreateUploadInput | undefined
    expect(input?.metadata).toEqual({
      oneofKind: "video",
      video: { width: 1280, height: 720, duration: 12, isAnimated: false },
    })
  })
})
