import { Method, type ClientMessage } from "@inline-chat/protocol/core"
import {
  mediaSendIntents,
  newClientKey,
  optimisticMediaRow,
  rowKey,
  sentMessageRowId,
  type AttachmentId,
  type MessageRow,
} from "@inline/core-protocol"
import { chatId as makeChatId } from "@inline/ids"
import { afterEach, describe, expect, it } from "vitest"
import { PART_SIZE } from "../../media"
import { testBytes } from "../../media/testing/transfer-server"
import { blobBytes, mediaOf, MediaModelHost } from "./media-host"
import { self } from "./model-host"

/**
 * Attachments and media sends through the real host: staged durably, sent
 * once after the upload with the server's media ID, across restarts; cancel
 * and retry.
 */

const chat = makeChatId(10)

const running: MediaModelHost[] = []
afterEach(async () => {
  for (const host of running.splice(0)) await host.dispose()
})

let attachmentSeq = 0
const attachmentId = (): AttachmentId => (++attachmentSeq).toString(16).padStart(24, "0")

const boot = async () => {
  const mh = new MediaModelHost()
  running.push(mh)
  mh.model.addUser(2n, "Ada")
  mh.model.addChat({ id: 10n, title: "Design", participants: [2n] })
  mh.model.postMessage({ chatId: 10n, fromId: 2n, text: "hello" })
  await mh.seedDisk()
  await mh.start()
  mh.ui.subscribeTo(2, { kind: "chatWindow", chatId: chat, anchor: "latest" })
  await mh.until(() => mh.ui.list(2).length === 1, "window")
  return mh
}

const attach = async (mh: MediaModelHost, id: AttachmentId, bytes: number, kind: "photo" | "document" = "photo") => {
  mh.intent(`attach-${id}`, {
    kind: "attachFile",
    attachmentId: id,
    file: new Blob([testBytes(bytes, bytes) as Uint8Array<ArrayBuffer>], { type: kind === "photo" ? "image/jpeg" : "application/pdf" }),
    fileName: kind === "photo" ? "photo.jpg" : "notes.pdf",
    mimeType: kind === "photo" ? "image/jpeg" : "application/pdf",
    ...(kind === "photo" ? { width: 800, height: 600 } : {}),
  })
  expect((await mh.final(`attach-${id}`)).status).toBe("confirmed")
}

const rows = (mh: MediaModelHost) => mh.ui.rows(2) as MessageRow[]
const row = (mh: MediaModelHost, clientKey: string) =>
  mh.ui.state.rows.get(rowKey("message", sentMessageRowId(chat, clientKey))) as MessageRow | undefined
const sends = (mh: MediaModelHost) =>
  mh.transport.sent.filter(
    (message: ClientMessage) =>
      message.body.oneofKind === "rpcCall" && message.body.rpcCall.input.oneofKind === "sendMessage",
  )
const sendInputs = (mh: MediaModelHost) =>
  sends(mh).map((message) => {
    const input = message.body.oneofKind === "rpcCall" ? message.body.rpcCall.input : undefined
    return input?.oneofKind === "sendMessage" ? input.sendMessage : undefined
  })
const uploadsLeft = async (mh: MediaModelHost) => (await mh.bytes.list(`accounts/u${self}/media/uploads/`)).length
const jobsLeft = async (mh: MediaModelHost) => (await mh.bytes.list(`accounts/u${self}/media/jobs/`)).length

describe("attachFile", () => {
  it("stages the file and shows its bytes, info and upload progress", async () => {
    const mh = await boot()
    mh.transfers.fault({ method: Method.SAVE_UPLOAD_PART, kind: "hold-before", times: 10 })
    const id = attachmentId()
    await attach(mh, id, PART_SIZE * 2)
    mh.ui.subscribeTo(5, { kind: "media", media: { kind: "attachment", attachmentId: id } })
    await mh.until(() => mediaOf(mh.ui, 5)?.state === "ready", "attachment ready")
    const resource = mediaOf(mh.ui, 5)!
    expect(resource.attachment).toMatchObject({ kind: "photo", width: 800, height: 600, size: PART_SIZE * 2 })
    expect(resource.upload).toMatchObject({ totalBytes: PART_SIZE * 2 })
    expect((await blobBytes(resource.blob))!.length).toBe(PART_SIZE * 2)
    await mh.until(() => {
      for (const held of mh.transfers.held()) held.release()
      return mediaOf(mh.ui, 5)?.upload?.state === "complete"
    }, "uploaded")
  })
})

describe("sendMedia", () => {
  it("one attachment: optimistic row with its final size, uploaded, sent once with the media ID", async () => {
    const mh = await boot()
    const id = attachmentId()
    await attach(mh, id, PART_SIZE + 10)
    const clientKey = newClientKey()
    const [intent] = mediaSendIntents({ chatId: chat, text: "look", attachments: [{ attachmentId: id, clientKey }] })
    mh.transport.hold()
    mh.intent("send", intent!)
    await mh.until(() => mh.ui.result("send")?.status === "accepted", "accepted")
    await mh.until(() => row(mh, clientKey) != null, "optimistic row")
    const optimistic = row(mh, clientKey)!
    const info = mediaOf(mh.ui, 99)?.attachment
    expect(info).toBeUndefined()
    expect(optimistic).toMatchObject({
      state: "sending",
      text: "look",
      upload: { attachmentId: id, attachment: { kind: "photo", width: 800, height: 600 } },
      media: { kind: "photo", photo: { sizes: [{ width: 800, height: 600 }] } },
    })
    // The UI builds the same row from the attachment's info (and its transaction ID).
    expect(optimisticMediaRow(intent!, optimistic.upload!.attachment, self, optimistic.date, "send")).toEqual(optimistic)
    await mh.settleUntil(mh.transport.release())
    expect((await mh.final("send")).status).toBe("confirmed")
    await mh.synced()
    const sent = row(mh, clientKey)!
    expect(sent.state).toBe("sent")
    expect(sent.messageId).toBeDefined()
    expect(sent.upload).toBeUndefined()
    expect(sendInputs(mh)).toHaveLength(1)
    expect(sendInputs(mh)[0]!.media?.media.oneofKind).toBe("photo")
    expect(mh.model.messagesWithRandomId(BigInt(clientKey))).toHaveLength(1)
    expect(mh.transfers.finalized).toHaveLength(1)
    expect(await uploadsLeft(mh)).toBe(0)
    expect(await jobsLeft(mh)).toBe(0)
    expect(await mh.disk.count("pending_transaction")).toBe(0)
  })

  it("three attachments: three messages in order, the caption on the first", async () => {
    const mh = await boot()
    const items = [
      { attachmentId: attachmentId(), clientKey: newClientKey() },
      { attachmentId: attachmentId(), clientKey: newClientKey() },
      { attachmentId: attachmentId(), clientKey: newClientKey() },
    ]
    // The first upload is the slowest: order still holds.
    mh.transfers.latency = (method, input) =>
      method === Method.SAVE_UPLOAD_PART && input.oneofKind === "saveUploadPart" && input.saveUploadPart.partIndex === 2
        ? 5_000
        : 0
    await attach(mh, items[0]!.attachmentId, PART_SIZE * 3, "document")
    await attach(mh, items[1]!.attachmentId, 1000)
    await attach(mh, items[2]!.attachmentId, 2000)
    const intents = mediaSendIntents({ chatId: chat, text: "three", attachments: items })
    intents.forEach((intent, index) => mh.intent(`s${index}`, intent))
    for (let index = 0; index < 3; index++) expect((await mh.final(`s${index}`)).status).toBe("confirmed")
    const inputs = sendInputs(mh)
    expect(inputs.map((input) => input!.randomId?.toString())).toEqual(items.map((item) => item.clientKey))
    expect(inputs.map((input) => input!.message ?? "")).toEqual(["three", "", ""])
    expect(inputs.map((input) => input!.media?.media.oneofKind)).toEqual(["document", "photo", "photo"])
    expect(rows(mh).map((message) => message.clientKey).filter(Boolean)).toEqual(items.map((item) => item.clientKey))
    expect(mh.transfers.finalized).toHaveLength(3)
  })

  it("a restart between the upload and the send's acknowledgement sends exactly once", async () => {
    const mh = await boot()
    const id = attachmentId()
    await attach(mh, id, 4096)
    const clientKey = newClientKey()
    // The server applies the send but its answer is lost with the process.
    let armed = true
    mh.endpoint.interceptor = (frame) => {
      if (
        armed &&
        frame.kind === "result" &&
        frame.message.body.oneofKind === "rpcResult" &&
        frame.message.body.rpcResult.result.oneofKind === "sendMessage"
      ) {
        armed = false
        return "drop"
      }
      return "deliver"
    }
    mh.intent("send", mediaSendIntents({ chatId: chat, attachments: [{ attachmentId: id, clientKey }] })[0]!)
    await mh.until(() => sends(mh).length === 1 && !armed, "sent, answer lost")
    await mh.stop()
    expect(await mh.disk.count("pending_transaction")).toBe(1)
    await mh.start()
    mh.ui.subscribeTo(2, { kind: "chatWindow", chatId: chat, anchor: "latest" })
    await mh.until(() => mh.model.messagesWithRandomId(BigInt(clientKey)).length === 1 && sends(mh).length >= 1, "resent")
    await mh.until(() => row(mh, clientKey)?.state === "sent", "sent row")
    await mh.synced()
    expect(mh.model.messagesWithRandomId(BigInt(clientKey))).toHaveLength(1)
    expect(mh.transfers.finalized).toHaveLength(1)
    expect(await mh.disk.count("pending_transaction")).toBe(0)
    expect(await jobsLeft(mh)).toBe(0)
  })

  it("a restart before the upload finished resumes it and sends once", async () => {
    const mh = await boot()
    mh.transfers.fault({ method: Method.FINISH_UPLOAD, kind: "hold-before" })
    const id = attachmentId()
    await attach(mh, id, PART_SIZE * 2)
    const clientKey = newClientKey()
    mh.intent("send", mediaSendIntents({ chatId: chat, attachments: [{ attachmentId: id, clientKey }] })[0]!)
    await mh.until(() => mh.transfers.held().length === 1, "finish held")
    await mh.stop()
    await mh.start()
    mh.ui.subscribeTo(2, { kind: "chatWindow", chatId: chat, anchor: "latest" })
    await mh.until(() => row(mh, clientKey)?.state === "sent", "sent after restart")
    expect(mh.model.messagesWithRandomId(BigInt(clientKey))).toHaveLength(1)
    expect(mh.transfers.finalized).toHaveLength(1)
  })

  it("cancelling the message cancels its upload and nothing is sent", async () => {
    const mh = await boot()
    mh.transfers.fault({ method: Method.SAVE_UPLOAD_PART, kind: "hold-before", times: 10 })
    const id = attachmentId()
    await attach(mh, id, PART_SIZE * 3)
    const clientKey = newClientKey()
    mh.intent("send", mediaSendIntents({ chatId: chat, attachments: [{ attachmentId: id, clientKey }] })[0]!)
    await mh.until(() => row(mh, clientKey) != null && mh.transfers.held().length > 0, "uploading")
    mh.intent("del", { kind: "deleteMessages", chatId: chat, messageIds: [], clientKeys: [clientKey] })
    expect((await mh.final("del")).status).toBe("confirmed")
    await mh.until(() => row(mh, clientKey) == null, "row gone")
    for (const held of mh.transfers.held()) held.drop()
    await mh.synced()
    expect(sends(mh)).toHaveLength(0)
    expect(mh.transfers.callsOf(Method.CANCEL_UPLOAD).length).toBeGreaterThan(0)
    expect(await mh.disk.count("pending_transaction")).toBe(0)
    expect(await uploadsLeft(mh)).toBe(0)
    expect(rows(mh).map((message) => message.text)).toEqual(["hello"])
  })

  it("a failed upload leaves the message failed; retrySend uploads again and sends once", async () => {
    const mh = await boot()
    mh.transfers.finalizationFailure = { code: 3, retryable: false }
    const id = attachmentId()
    await attach(mh, id, 4096)
    const clientKey = newClientKey()
    mh.intent("send", mediaSendIntents({ chatId: chat, attachments: [{ attachmentId: id, clientKey }] })[0]!)
    expect(await mh.final("send")).toMatchObject({ status: "rejected", reason: "server" })
    await mh.until(() => row(mh, clientKey)?.state === "failed", "failed row")
    expect(row(mh, clientKey)!.upload).toBeDefined()
    expect(sends(mh)).toHaveLength(0)

    mh.transfers.finalizationFailure = undefined
    mh.intent("retry", { kind: "retrySend", chatId: chat, clientKey })
    expect((await mh.final("retry")).status).toBe("confirmed")
    await mh.until(() => row(mh, clientKey)?.state === "sent", "sent")
    expect(sends(mh)).toHaveLength(1)
    expect(mh.model.messagesWithRandomId(BigInt(clientKey))).toHaveLength(1)
  })

  it("rejects a send that names no staged attachment, and malformed attachments, as data", async () => {
    const mh = await boot()
    mh.intent("s", { kind: "sendMedia", chatId: chat, clientKey: newClientKey(), attachmentId: attachmentId() })
    expect(await mh.final("s")).toMatchObject({ status: "rejected", reason: "invalid" })
    mh.intent("a", {
      kind: "attachFile",
      attachmentId: "nope",
      file: new Blob(["x"]),
      fileName: "x",
      mimeType: "text/plain",
    })
    expect(await mh.final("a")).toMatchObject({ status: "rejected", reason: "invalid" })
  })
})
