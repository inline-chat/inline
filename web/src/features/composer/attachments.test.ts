import type { SendRequest } from "@inline/composer"
import { ATTACHMENT_PREVIEW_MAX_BYTES, type AttachmentInfo, type MessageRow, rowKey, sentMessageRowId } from "@inline/core-protocol"
import { type ChatID, messageId, type UserID } from "@inline/ids"
import { describe, expect, it } from "vitest"
import { fakeBlobUrls, scriptedCore } from "../media/test-support"
import { type AttachmentProber, serialProber } from "./attachment-probe"
import { createAttachmentDrafts, createComposerAttachments, followUploadActivity, withAttachments } from "./attachments"
import { createComposerModel } from "./model"

const chat = "7" as ChatID
const me = "9" as UserID

const file = (name: string, type: string, bytes = 1_000): File =>
  new File([new Uint8Array(Math.min(bytes, 16))], name, { type }) as File

/** A file whose `size` claims more bytes than it holds (limits without allocating them). */
const sized = (name: string, size: number): File => {
  const real = file(name, "video/mp4")
  Object.defineProperty(real, "size", { value: size })
  return real
}

const photoInfo = (name = "a.jpg"): AttachmentInfo => ({
  kind: "photo",
  fileName: name,
  mimeType: "image/jpeg",
  size: 900,
  width: 800,
  height: 600,
  preview: new Uint8Array([1, 2, 3]),
})

const setup = (options: { maxCount?: number; maxBytes?: number } = {}) => {
  const core = scriptedCore()
  const urls = fakeBlobUrls()
  let nextId = 0
  let nextKey = 100
  const attachments = createComposerAttachments({
    client: core.client,
    chatId: chat,
    userId: me,
    urls,
    clock: core.time,
    newAttachmentId: () => (++nextId).toString(16).padStart(24, "0"),
    newClientKey: () => String(++nextKey),
    placeRows: (row) => ({ row }),
    limits: options,
    prober: false,
    loadView: false,
  })
  const attachSub = (id: string) =>
    core.mediaSubs((ref) => ref.kind === "attachment" && ref.attachmentId === id)[0]?.sub
  /** The core staged it: `attachFile` confirmed, its resource has info and maybe upload. */
  const stage = async (id: string, info: AttachmentInfo = photoInfo(), upload?: { sent: number; total: number }) => {
    const tx = core.intents("attachFile").find(({ intent }) => intent.attachmentId === id)!.tx
    core.media(attachSub(id)!, {
      state: "ready",
      blob: new Blob([new Uint8Array(4)]),
      attachment: info,
      upload: { state: upload ? "uploading" : "staged", sentBytes: upload?.sent ?? 0, totalBytes: upload?.total ?? info.size },
    })
    core.settle(tx, "confirmed")
    await core.flush()
  }
  const request = (text: string, extra: Partial<SendRequest> = {}): SendRequest => ({
    kind: "send",
    text,
    entities: [],
    revision: 3,
    ...extra,
  })
  const ids = () => attachments.items.peek().map((item) => item.id)
  return { core, urls, attachments, attachSub, stage, request, ids }
}

describe("composer attachments: adding", () => {
  it("hands each file to the core at once and follows its progress", async () => {
    const { core, urls, attachments, stage, ids } = setup()
    attachments.add([file("a.jpg", "image/jpeg"), file("notes.pdf", "application/pdf")])
    const [photoId, pdfId] = ids()
    const posted = core.intents("attachFile").map(({ intent }) => intent)
    expect(posted.map((intent) => [intent.attachmentId, intent.fileName, intent.mimeType])).toEqual([
      [photoId, "a.jpg", "image/jpeg"],
      [pdfId, "notes.pdf", "application/pdf"],
    ])
    expect(posted[0]!.file).toBeInstanceOf(Blob)
    expect(core.mediaSubs().map((sub) => sub.ref)).toEqual([
      { kind: "attachment", attachmentId: photoId },
      { kind: "attachment", attachmentId: pdfId },
    ])
    const [photo, pdf] = attachments.items.peek()
    expect(photo!.kind).toBe("image")
    expect(photo!.thumbnailUrl).toBe(urls.created[0])
    expect(pdf!.kind).toBe("file")
    expect(pdf!.thumbnailUrl).toBeUndefined()
    expect(photo!.status.peek()).toEqual({ phase: "staging" })

    await stage(photoId!, photoInfo(), { sent: 300, total: 900 })
    expect(photo!.status.peek()).toEqual({ phase: "uploading", fraction: 1 / 3 })
    core.media(core.mediaSubs()[0]!.sub, {
      state: "ready",
      attachment: photoInfo(),
      upload: { state: "complete", sentBytes: 900, totalBytes: 900 },
    })
    expect(photo!.status.peek()).toEqual({ phase: "uploaded" })
    expect(attachments.hasAttachments.peek()).toBe(true)
  })

  it("never previews SVG or other non-raster files through an object URL", () => {
    const { urls, attachments } = setup()
    attachments.add([file("logo.svg", "image/svg+xml"), file("page.html", "text/html"), file("b.png", "image/png")])
    expect(attachments.items.peek().map((item) => item.thumbnailUrl === undefined)).toEqual([true, true, false])
    expect(urls.created).toHaveLength(1)
  })

  it("remove revokes the thumbnail, stops following it and discards it in the core after it was staged", async () => {
    const { core, urls, attachments, stage, ids } = setup()
    attachments.add([file("a.jpg", "image/jpeg")])
    const [id] = ids()
    attachments.remove(id!)
    expect(attachments.items.peek()).toEqual([])
    expect(urls.live.size).toBe(0)
    expect(core.mediaSubs()).toHaveLength(0)
    await core.flush()
    expect(core.intents("discardAttachment")).toHaveLength(0)
    const tx = core.intents("attachFile")[0]!.tx
    core.settle(tx, "confirmed")
    await core.flush()
    expect(core.intents("discardAttachment").map(({ intent }) => intent.attachmentId)).toEqual([id])
    void stage
  })
})

describe("composer attachments: failure and retry", () => {
  it("a refused attachFile shows why; retry hands the same file to the core under a new ID", async () => {
    const { core, urls, attachments, ids } = setup()
    const picked = file("a.jpg", "image/jpeg")
    attachments.add([picked])
    const [first] = ids()
    core.settle(core.intents("attachFile")[0]!.tx, "rejected", "storageFull")
    await core.flush()
    expect(attachments.items.peek()[0]!.status.peek()).toEqual({
      phase: "failed",
      message: "Not enough storage on this device to attach this file.",
    })
    attachments.retry(first!)
    await core.flush()
    const [second] = ids()
    expect(second).not.toBe(first)
    const attached = core.intents("attachFile")
    expect(attached).toHaveLength(2)
    expect(attached[1]!.intent.file).toBe(picked)
    expect(core.intents("discardAttachment").map(({ intent }) => intent.attachmentId)).toEqual([first])
    // One thumbnail alive: the retried item's.
    expect(urls.live.size).toBe(1)
  })

  it("a failed upload shows as failed and can be retried", async () => {
    const { core, attachments, stage, ids } = setup()
    attachments.add([file("a.jpg", "image/jpeg")])
    const [id] = ids()
    await stage(id!)
    core.media(core.mediaSubs()[0]!.sub, {
      state: "ready",
      attachment: photoInfo(),
      upload: { state: "failed", sentBytes: 0, totalBytes: 900, retryable: true },
    })
    expect(attachments.items.peek()[0]!.status.peek()).toEqual({ phase: "failed", message: "Couldn’t upload. Try again." })
    attachments.retry(id!)
    expect(ids()[0]).not.toBe(id)
    expect(core.intents("attachFile")).toHaveLength(2)
  })
})

describe("composer attachments: sending", () => {
  it("sends one attachment with the text as its caption and its optimistic row, then clears the strip", async () => {
    const { core, urls, attachments, stage, request, ids } = setup()
    attachments.add([file("a.jpg", "image/jpeg")])
    const [id] = ids()
    await stage(id!)
    const outcome = attachments.send(request("look", { replyTo: { messageId: messageId("55") } }))
    await core.flush()
    const [sent] = core.intents("sendMedia")
    expect(sent!.intent).toMatchObject({ kind: "sendMedia", chatId: chat, attachmentId: id, text: "look", replyToMessageId: "55", clientKey: "101" })
    // The optimistic row is in the store before the core answers, with its final size.
    const row = core.client.store.peekRow(rowKey("message", sentMessageRowId(chat, "101"))) as MessageRow
    expect(row.upload?.attachmentId).toBe(id)
    expect(row.media).toMatchObject({ kind: "photo", photo: { sizes: [{ width: 800, height: 600 }] } })
    expect(row.text).toBe("look")
    // Not cleared until the core accepts.
    expect(attachments.items.peek()).toHaveLength(1)
    core.settle(sent!.tx, "accepted")
    expect(await outcome).toEqual({ status: "accepted" })
    expect(attachments.items.peek()).toEqual([])
    expect(urls.live.size).toBe(0)
    // Its upload is still running: followed (for the upload activity) until it ends, then released.
    expect(core.mediaSubs()).toHaveLength(1)
    core.media(core.mediaSubs()[0]!.sub, { state: "ready", blob: new Blob([new Uint8Array(4)]), upload: { state: "complete", sentBytes: 900, totalBytes: 900 } })
    expect(core.mediaSubs()).toHaveLength(0)
    expect(core.intents("discardAttachment")).toHaveLength(0)
  })

  it("sends three attachments as three messages, in order, the text and reply on the first only", async () => {
    const { core, attachments, stage, request, ids } = setup()
    attachments.add([file("a.jpg", "image/jpeg"), file("b.jpg", "image/jpeg"), file("c.pdf", "application/pdf")])
    const order = ids()
    await stage(order[0]!, photoInfo("a.jpg"))
    await stage(order[1]!, photoInfo("b.jpg"))
    await stage(order[2]!, { kind: "document", fileName: "c.pdf", mimeType: "application/pdf", size: 2_000 })
    const outcome = attachments.send(request("three things", { replyTo: { messageId: messageId("8") } }))
    await core.flush()
    const sends = core.intents("sendMedia")
    expect(sends.map(({ intent }) => intent.attachmentId)).toEqual(order)
    expect(sends.map(({ intent }) => intent.text)).toEqual(["three things", undefined, undefined])
    expect(sends.map(({ intent }) => intent.replyToMessageId)).toEqual(["8", undefined, undefined])
    expect(new Set(sends.map(({ intent }) => intent.clientKey)).size).toBe(3)
    // The first send's commit consumes the draft (its revision), as a text send does.
    expect(sends.map(({ intent }) => intent.draftRevision)).toEqual([3, undefined, undefined])
    // Each optimistic row carries its intent's `tx`: the same row the core shows from the outbox.
    for (const { intent, tx } of sends) {
      const row = core.client.store.peekRow(rowKey("message", sentMessageRowId(chat, intent.clientKey))) as MessageRow
      expect(row.tx).toBe(tx)
    }
    for (const { tx } of sends) core.settle(tx, "accepted")
    expect(await outcome).toEqual({ status: "accepted" })
    expect(attachments.items.peek()).toEqual([])
  })

  it("a rejected send keeps the attachments and the text; sending again reuses the client keys", async () => {
    const { core, attachments, stage, request, ids } = setup()
    attachments.add([file("a.jpg", "image/jpeg"), file("b.jpg", "image/jpeg")])
    for (const id of ids()) await stage(id)
    const first = attachments.send(request("hi"))
    await core.flush()
    const sends = core.intents("sendMedia")
    for (const { tx } of sends) core.settle(tx, "rejected", "storageFull")
    expect(await first).toEqual({ status: "rejected", reason: "storageFull" })
    expect(attachments.items.peek()).toHaveLength(2)
    const again = attachments.send(request("hi"))
    await core.flush()
    const resent = core.intents("sendMedia").slice(2)
    expect(resent.map(({ intent }) => intent.clientKey)).toEqual(sends.map(({ intent }) => intent.clientKey))
    for (const { tx } of resent) core.settle(tx, "accepted")
    expect(await again).toEqual({ status: "accepted" })
  })

  it("when only later attachments are refused, the text is sent and they stay with a note", async () => {
    const { core, attachments, stage, request, ids } = setup()
    attachments.add([file("a.jpg", "image/jpeg"), file("b.jpg", "image/jpeg")])
    const [a, b] = ids()
    for (const id of ids()) await stage(id)
    const outcome = attachments.send(request("caption"))
    await core.flush()
    const [one, two] = core.intents("sendMedia")
    core.settle(one!.tx, "accepted")
    core.settle(two!.tx, "rejected", "invalid")
    expect(await outcome).toEqual({ status: "accepted" })
    expect(ids()).toEqual([b])
    expect(attachments.notice.peek()).toBe("1 attachment couldn’t be sent. It is still here.")
    void a
  })

  it("refuses to send while an attachment failed to stage, without posting anything", async () => {
    const { core, attachments, request } = setup()
    attachments.add([file("a.jpg", "image/jpeg")])
    core.settle(core.intents("attachFile")[0]!.tx, "rejected", "invalid")
    await core.flush()
    expect(await attachments.send(request(""))).toEqual({ status: "rejected", reason: "attachmentFailed" })
    expect(core.intents("sendMedia")).toHaveLength(0)
  })

  it("gives up waiting for the core to describe an attachment", async () => {
    const { core, attachments, request } = setup()
    attachments.add([file("a.jpg", "image/jpeg")])
    core.settle(core.intents("attachFile")[0]!.tx, "confirmed")
    await core.flush()
    const outcome = attachments.send(request(""))
    await core.flush()
    core.time.advance(15_000)
    expect(await outcome).toEqual({ status: "rejected", reason: "attachmentNotReady" })
  })
})

describe("composer attachments: limits", () => {
  it("refuses files over the server's limit, empty files, and more than the strip holds, saying so", () => {
    const { core, attachments } = setup({ maxCount: 2 })
    attachments.add([sized("huge.mov", 500_000_001)])
    expect(attachments.notice.peek()).toBe("“huge.mov” is too large. The upload limit is 500 MB.")
    attachments.add([file("a.jpg", "image/jpeg"), new File([], "empty.txt"), file("b.jpg", "image/jpeg"), file("c.jpg", "image/jpeg")])
    expect(attachments.notice.peek()).toBe("“empty.txt” is empty. You can attach up to 2 files at a time.")
    expect(attachments.items.peek().map((item) => item.fileName)).toEqual(["a.jpg", "b.jpg"])
    expect(core.intents("attachFile")).toHaveLength(2)
    attachments.add([sized("x.mov", 600_000_000), sized("y.mov", 600_000_000)])
    expect(attachments.notice.peek()).toBe("2 files are too large. The upload limit is 500 MB.")
    attachments.dismissNotice()
    expect(attachments.notice.peek()).toBeNull()
  })
})

describe("composer attachments: in the composer", () => {
  it("makes the composer sendable with no text, sends through the core, clears after acceptance, and leaves edits to text", async () => {
    const { core, attachments, stage, ids } = setup()
    const textSends: SendRequest[] = []
    const model = createComposerModel(
      withAttachments(
        {
          clock: core.time,
          safeUrl: (url) => url,
          send: (request) => {
            textSends.push(request)
            return { status: "accepted" }
          },
        },
        attachments,
      ),
    )
    expect(model.composer.canSend.peek()).toBe(false)
    model.composer.pasteFiles([file("a.jpg", "image/jpeg")])
    expect(model.composer.canSend.peek()).toBe(true)
    await stage(ids()[0]!)
    model.composer.insertText("caption")
    const sending = model.composer.send()
    await core.flush()
    expect(model.composer.doc.peek().text).toBe("caption")
    core.settle(core.intents("sendMedia")[0]!.tx, "accepted")
    expect(await sending).toBe(true)
    expect(model.composer.doc.peek().text).toBe("")
    expect(textSends).toEqual([])
    // With no attachments, text goes the usual way.
    model.composer.insertText("plain")
    await model.composer.send()
    expect(textSends.map((request) => request.text)).toEqual(["plain"])
    model.dispose()
  })

  it("while editing a message, as on the Mac: a pasted or dropped file joins the strip, Save edits only, the file waits for the next send", async () => {
    // Mac: `GlassComposeAppKit.handleAttachments` and `handleFileDrop` check only
    // `canMutateDraft` (true in a chat while editing); `send()` with
    // `editingMsgId` sends `editMessage` and leaves the attachments in the draft.
    const { core, attachments, stage, ids } = setup()
    const textSends: SendRequest[] = []
    const model = createComposerModel(
      withAttachments(
        {
          clock: core.time,
          safeUrl: (url) => url,
          send: (request) => {
            textSends.push(request)
            return { status: "accepted" }
          },
        },
        attachments,
      ),
    )
    model.composer.startEdit({ messageId: messageId("40") }, { text: "old" })
    // Pasted on the editor (the binding hands files to pasteFiles) and dropped on it (the same path).
    model.composer.pasteFiles([file("a.jpg", "image/jpeg")])
    model.composer.pasteFiles([file("b.pdf", "application/pdf")])
    expect(attachments.items.peek().map((item) => item.fileName)).toEqual(["a.jpg", "b.pdf"])
    // An edit with no text cannot be saved because of attachments.
    model.composer.selectAll()
    model.composer.deleteSelection()
    expect(model.composer.canSend.peek()).toBe(false)
    model.composer.insertText("new")
    expect(await model.composer.send()).toBe(true)
    expect(textSends).toEqual([expect.objectContaining({ kind: "edit", text: "new", edit: { messageId: "40" } })])
    expect(core.intents("sendMedia")).toEqual([])
    expect(attachments.items.peek()).toHaveLength(2)
    // The edit is over: the files go with the next message.
    expect(model.composer.editing.peek()).toBeNull()
    for (const id of ids()) await stage(id)
    const sending = model.composer.send()
    await core.flush()
    expect(core.intents("sendMedia")).toHaveLength(2)
    for (const { tx } of core.intents("sendMedia")) core.settle(tx, "accepted")
    expect(await sending).toBe(true)
    model.dispose()
  })

  it("words the attachment reasons", async () => {
    const { core, attachments } = setup()
    const model = createComposerModel(
      withAttachments({ clock: core.time, safeUrl: (url) => url, send: () => ({ status: "accepted" }) }, attachments),
    )
    attachments.add([file("a.jpg", "image/jpeg")])
    core.settle(core.intents("attachFile")[0]!.tx, "rejected", "invalid")
    await core.flush()
    await model.composer.send()
    expect(model.errorText.peek()).toBe("An attachment couldn’t be added. Remove it or try again; your message is still here.")
    model.dispose()
  })

  it("keeps a chat's attachments for the session across composer models", () => {
    const core = scriptedCore()
    const urls = fakeBlobUrls()
    const drafts = createAttachmentDrafts({ client: core.client, userId: me, urls, clock: core.time, prober: false, loadView: false })
    const first = drafts.forChat(chat)
    first.add([file("a.jpg", "image/jpeg")])
    expect(drafts.forChat(chat)).toBe(first)
    expect(drafts.forChat("8" as ChatID)).not.toBe(first)
    drafts.dispose()
    expect(urls.live.size).toBe(0)
    expect(core.mediaSubs()).toHaveLength(0)
    expect(core.intents("discardAttachment")).toHaveLength(0)
  })
})

describe("composer attachments: size, length and preview before attachFile", () => {
  const jpeg = new Uint8Array([0xff, 0xd8, 0xff, 0xd9])

  const probed = (prober: AttachmentProber, extra: { probeTimeoutMs?: number; loadView?: () => void } = {}) => {
    const core = scriptedCore()
    let nextId = 0
    const attachments = createComposerAttachments({
      client: core.client,
      chatId: chat,
      userId: me,
      urls: fakeBlobUrls(),
      clock: core.time,
      newAttachmentId: () => (++nextId).toString(16).padStart(24, "0"),
      prober,
      loadView: extra.loadView ?? false,
      ...(extra.probeTimeoutMs !== undefined ? { probeTimeoutMs: extra.probeTimeoutMs } : {}),
    })
    const tick = async (ms = 0) => {
      core.time.advance(ms)
      await core.flush()
    }
    return { core, attachments, tick }
  }

  it("shows the attachment at once, probes a task later, then posts attachFile with size and preview", async () => {
    const calls: string[] = []
    const { core, attachments, tick } = probed((_file, kind) => {
      calls.push(kind)
      return Promise.resolve({ width: 4032, height: 3024, preview: jpeg })
    })
    attachments.add([file("a.jpg", "image/jpeg")])
    expect(attachments.items.peek()).toHaveLength(1)
    expect(calls).toEqual([])
    expect(core.intents("attachFile")).toEqual([])
    await tick()
    expect(calls).toEqual(["image"])
    const [posted] = core.intents("attachFile").map(({ intent }) => intent)
    expect(posted).toMatchObject({ width: 4032, height: 3024, preview: jpeg })
    expect(posted?.as).toBeUndefined()
  })

  it("sends a video's size, length and poster frame", async () => {
    const { core, attachments, tick } = probed(() => Promise.resolve({ width: 1280, height: 720, duration: 12, preview: jpeg }))
    attachments.add([file("clip.mp4", "video/mp4")])
    await tick()
    expect(core.intents("attachFile")[0]?.intent).toMatchObject({ width: 1280, height: 720, duration: 12, preview: jpeg })
  })

  it("applies the Mac's rule: very small or very wide images go as files (GlassComposeAppKit.shouldSendAsFile)", async () => {
    const sizes = [
      { width: 40, height: 30 },
      { width: 4200, height: 200 },
      { width: 49, height: 400 },
    ]
    const { core, attachments, tick } = probed(() => Promise.resolve({ ...sizes.shift()!, preview: jpeg }))
    attachments.add([file("icon.png", "image/png"), file("banner.png", "image/png"), file("tall.png", "image/png")])
    for (let i = 0; i < 3; i++) await tick()
    const posted = core.intents("attachFile").map(({ intent }) => intent)
    expect(posted.map((intent) => intent.as)).toEqual(["document", "document", undefined])
    // As a file: no photo size or preview.
    expect(posted[0]).not.toHaveProperty("width")
    expect(posted[2]).toMatchObject({ width: 49, height: 400 })
  })

  it("hands the file over without hints when the probe fails or takes too long", async () => {
    const failing = probed(() => Promise.reject(new Error("cannot decode")))
    failing.attachments.add([file("a.heic", "image/png")])
    await failing.tick()
    expect(failing.core.intents("attachFile")[0]?.intent).not.toHaveProperty("width")

    const stuck = probed(() => new Promise(() => undefined), { probeTimeoutMs: 1_000 })
    stuck.attachments.add([file("b.mp4", "video/mp4")])
    await stuck.tick()
    expect(stuck.core.intents("attachFile")).toEqual([])
    await stuck.tick(1_000)
    expect(stuck.core.intents("attachFile")).toHaveLength(1)
    expect(stuck.core.intents("attachFile")[0]?.intent).not.toHaveProperty("duration")
  })

  it("drops a preview over the contract's limit, and never probes documents", async () => {
    const kinds: string[] = []
    const { core, attachments, tick } = probed((_file, kind) => {
      kinds.push(kind)
      return Promise.resolve({ width: 800, height: 600, preview: new Uint8Array(ATTACHMENT_PREVIEW_MAX_BYTES + 1) })
    })
    attachments.add([file("notes.pdf", "application/pdf")])
    expect(core.intents("attachFile")).toHaveLength(1)
    attachments.add([file("a.jpg", "image/jpeg")])
    await tick()
    expect(kinds).toEqual(["image"])
    expect(core.intents("attachFile")[1]?.intent).not.toHaveProperty("preview")
  })

  it("removed before its probe ends: nothing reaches the core, not even a discard", async () => {
    const { core, attachments, tick } = probed(() => Promise.resolve({ width: 800, height: 600 }))
    attachments.add([file("a.jpg", "image/jpeg")])
    attachments.remove(attachments.items.peek()[0]!.id)
    await tick()
    expect(core.intents("attachFile")).toEqual([])
    expect(core.intents("discardAttachment")).toEqual([])
  })

  it("decodes one file at a time across every chat of the session", async () => {
    const core = scriptedCore()
    let running = 0
    let most = 0
    const finishers: (() => void)[] = []
    const prober: AttachmentProber = () =>
      new Promise((resolve) => {
        running += 1
        most = Math.max(most, running)
        finishers.push(() => {
          running -= 1
          resolve({ width: 10, height: 10 })
        })
      })
    const drafts = createAttachmentDrafts({ client: core.client, userId: me, urls: fakeBlobUrls(), clock: core.time, prober: serialProber(prober), loadView: false })
    drafts.forChat(chat).add([file("a.jpg", "image/jpeg"), file("b.jpg", "image/jpeg")])
    drafts.forChat("8" as ChatID).add([file("c.mp4", "video/mp4")])
    core.time.advance(0)
    await core.flush()
    for (let i = 0; i < 3; i++) {
      expect(running).toBe(1)
      finishers.shift()!()
      await core.flush()
    }
    expect(most).toBe(1)
    expect(core.intents("attachFile")).toHaveLength(3)
    drafts.dispose()
  })

  it("loads the strip's view on the first file, not before", () => {
    let loads = 0
    const { attachments } = probed(() => Promise.resolve({}), { loadView: () => (loads += 1) })
    expect(loads).toBe(0)
    attachments.add([file("notes.pdf", "application/pdf")])
    expect(loads).toBe(1)
  })
})

describe("composer attachments: upload activity", () => {
  it("reports the strongest kind of a sent attachment while its upload runs, and nothing for the strip alone", async () => {
    const { core, attachments, stage, request } = setup()
    attachments.add([file("a.jpg", "image/jpeg"), file("clip.mp4", "video/mp4")])
    const [photoId, videoId] = attachments.items.peek().map((item) => item.id)
    await stage(photoId!, photoInfo(), { sent: 10, total: 900 })
    await stage(videoId!, { kind: "video", fileName: "clip.mp4", mimeType: "video/mp4", size: 5_000, width: 1280, height: 720, duration: 3 }, { sent: 0, total: 5_000 })
    // In the strip and uploading: not reported (the user has not sent it).
    expect(attachments.activity!.peek()).toBeNull()
    const reported: string[] = []
    const stop = followUploadActivity(attachments.activity!, {
      beginActivity: (kind) => {
        reported.push(`begin ${kind}`)
        return () => reported.push(`end ${kind}`)
      },
    })
    const sending = attachments.send(request("look"))
    await core.flush()
    for (const { tx } of core.intents("sendMedia")) core.settle(tx, "accepted")
    expect(await sending).toEqual({ status: "accepted" })
    expect(attachments.items.peek()).toEqual([])
    expect(attachments.activity!.peek()).toBe("uploadingVideo")
    // The video finishes: the photo is still going.
    core.media(core.mediaSubs((ref) => ref.kind === "attachment" && ref.attachmentId === videoId)[0]!.sub, {
      state: "ready",
      blob: new Blob([new Uint8Array(4)]),
      upload: { state: "complete", sentBytes: 5_000, totalBytes: 5_000 },
    })
    expect(attachments.activity!.peek()).toBe("uploadingPhoto")
    core.media(core.mediaSubs((ref) => ref.kind === "attachment" && ref.attachmentId === photoId)[0]!.sub, {
      state: "ready",
      blob: new Blob([new Uint8Array(4)]),
      upload: { state: "failed", sentBytes: 10, totalBytes: 900 },
    })
    expect(attachments.activity!.peek()).toBeNull()
    expect(reported).toEqual(["begin uploadingVideo", "end uploadingVideo", "begin uploadingPhoto", "end uploadingPhoto"])
    // Every subscription is released once the uploads ended.
    expect(core.mediaSubs()).toEqual([])
    stop()
  })

  it("ends a running activity when the pane stops following it, and releases on dispose", async () => {
    const { core, attachments, stage, request } = setup()
    attachments.add([file("notes.pdf", "application/pdf")])
    const [id] = attachments.items.peek().map((item) => item.id)
    await stage(id!, { kind: "document", fileName: "notes.pdf", mimeType: "application/pdf", size: 900 }, { sent: 1, total: 900 })
    const sending = attachments.send(request(""))
    await core.flush()
    core.settle(core.intents("sendMedia")[0]!.tx, "accepted")
    await sending
    const reported: string[] = []
    const stop = followUploadActivity(attachments.activity!, {
      beginActivity: (kind) => {
        reported.push(`begin ${kind}`)
        return () => reported.push(`end ${kind}`)
      },
    })
    stop()
    expect(reported).toEqual(["begin uploadingDocument", "end uploadingDocument"])
    attachments.dispose()
    expect(core.mediaSubs()).toEqual([])
  })
})
