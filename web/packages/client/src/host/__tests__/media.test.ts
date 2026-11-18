import { chatId as makeChatId, messageId as makeMessageId } from "@inline/ids"
import { afterEach, describe, expect, it } from "vitest"
import { DbObjectKind, messageKey, type Message } from "../../database/models"
import { bytesEqual } from "../../media/bytes"
import { testBytes } from "../../media/testing/transfer-server"
import type { MediaState } from "@inline/core-protocol"
import { blobBytes, mediaOf, MediaModelHost } from "./media-host"
import { self } from "./model-host"

/**
 * `media` subscriptions through the real host: a download goes queued,
 * downloading and ready with a Blob handle; an unsubscribed file can be
 * evicted and comes back by downloading again; an expired signed URL is
 * refreshed through `GET_MESSAGES` into the replica; sign-out erases the
 * account's media.
 */

const chat = makeChatId(10)
const SIZE = 700 * 1024

const running: MediaModelHost[] = []
afterEach(async () => {
  for (const host of running.splice(0)) await host.dispose()
})

const photoMedia = (fileUniqueId: string, url: string, size = SIZE) => ({
  media: {
    oneofKind: "photo",
    photo: {
      photo: {
        id: 77n,
        date: 1n,
        format: 1,
        sizes: [{ type: "c", w: 320, h: 240, size, fileUniqueId, cdnUrl: url }],
      },
    },
  },
})

/** A chat whose messages 1..count carry a photo each, cached nowhere. */
const boot = async (count = 1) => {
  const mh = new MediaModelHost()
  running.push(mh)
  mh.model.addUser(2n, "Ada")
  mh.model.addChat({ id: 10n, title: "Design", participants: [2n] })
  const ids: bigint[] = []
  for (let index = 0; index < count; index++) {
    mh.model.postMessage({ chatId: 10n, fromId: 2n, text: `photo ${index}` })
  }
  for (const message of mh.model.chats.get(10n)!.messages.values()) ids.push(message.id)
  for (const index of ids.keys()) {
    mh.transfers.addFile(`photo-${index}-file`, testBytes(SIZE, index + 1), "image/jpeg")
  }
  await mh.seedDisk([], (db) => {
    for (const [index, id] of ids.entries()) {
      const key = messageKey(chat, makeMessageId(id))
      const message = db.get(db.ref(DbObjectKind.Message, key)) as Message
      db.replace({
        ...message,
        media: photoMedia(`photo-${index}-file`, mh.transfers.fileUrl(`photo-${index}-file`)) as never,
      })
    }
  })
  await mh.start()
  return { mh, ids }
}

const ref = (id: bigint) => ({ kind: "message" as const, chatId: chat, messageId: makeMessageId(id), size: "c" })

describe("media subscriptions", () => {
  it("goes queued, downloading and ready, with the bytes as a Blob handle", async () => {
    const { mh, ids } = await boot(5)
    for (let index = 0; index < 5; index++) mh.transfers.httpFault({ kind: "delay", ms: 2_000, times: 2 })
    for (const [index, id] of ids.entries()) {
      mh.ui.subscribeTo(10 + index, { kind: "media", media: ref(id) })
    }
    await mh.until(() => ids.every((_, index) => mediaOf(mh.ui, 10 + index)?.state === "ready"), "all ready")
    const states = new Map<number, MediaState[]>()
    for (const patch of mh.ui.patches) {
      for (const change of patch.resources) {
        if (change.value.kind !== "media") continue
        const seen = states.get(change.sub - 10) ?? []
        if (seen.at(-1) !== change.value.state) seen.push(change.value.state)
        states.set(change.sub - 10, seen)
      }
    }
    // At most four download at once: one waited in the queue. (Messages not
    // resident yet show `absent` until they are read from disk.)
    const paths = Array.from(states.values(), (seen) => seen.filter((state) => state !== "absent").join(" "))
    expect(paths.filter((path) => path === "queued downloading ready")).toHaveLength(1)
    expect(paths.filter((path) => path === "downloading ready")).toHaveLength(4)
    const ready = mediaOf(mh.ui, 10)!
    expect(ready).toMatchObject({ state: "ready", size: SIZE })
    expect(ready.blob).toBeInstanceOf(Blob)
    expect(bytesEqual((await blobBytes(ready.blob))!, testBytes(SIZE, 1))).toBe(true)
  })

  it("keeps a file while subscribed; once released it can be evicted, and a new subscription downloads it again", async () => {
    const { mh, ids } = await boot(1)
    mh.ui.subscribeTo(10, { kind: "media", media: ref(ids[0]!) })
    await mh.until(() => mediaOf(mh.ui, 10)?.state === "ready", "ready")
    const requests = mh.transfers.httpRequests.length
    const media = (mh.host as unknown as { account: { media: { core: import("../../media").MediaCore } } }).account.media.core
    // Over budget while subscribed: the pinned file stays.
    await mh.settleUntil(media.updateSettings({ ...media.settings, cacheBudgetBytes: 1 }))
    expect(media.cache.has({ fileUniqueId: "photo-0-file", variant: "c" })).toBe(true)
    mh.ui.post({ kind: "unsubscribe", sub: 10 })
    await mh.synced()
    await mh.settleUntil(media.cache.evictToBudget())
    expect(media.cache.has({ fileUniqueId: "photo-0-file", variant: "c" })).toBe(false)
    await mh.settleUntil(media.updateSettings({ ...media.settings, cacheBudgetBytes: 1 << 30 }))
    mh.ui.subscribeTo(11, { kind: "media", media: ref(ids[0]!) })
    await mh.until(() => mediaOf(mh.ui, 11)?.state === "ready", "ready again")
    expect(mh.transfers.httpRequests.length).toBeGreaterThan(requests)
  })

  it("refreshes an expired signed URL through GET_MESSAGES, and the row carries the fresh one", async () => {
    const { mh, ids } = await boot(1)
    const id = ids[0]!
    mh.transfers.expireLinks()
    mh.respond = (_method, input) => {
      if (input.oneofKind !== "getMessages") return undefined
      const message = mh.model.chats.get(10n)!.messages.get(id)!
      return {
        result: {
          oneofKind: "getMessages",
          getMessages: {
            messages: [
              {
                id,
                chatId: 10n,
                fromId: message.fromId,
                peerId: { type: { oneofKind: "chat", chat: { chatId: 10n } } },
                date: BigInt(message.date),
                message: message.text,
                out: false,
                media: photoMedia("photo-0-file", mh.transfers.fileUrl("photo-0-file")),
              },
            ],
          },
        } as never,
      }
    }
    mh.ui.subscribeTo(2, { kind: "chatWindow", chatId: chat, anchor: "latest" })
    mh.ui.subscribeTo(10, { kind: "media", media: ref(id) })
    await mh.until(() => mediaOf(mh.ui, 10)?.state === "ready", "ready after refresh")
    expect(mh.extraRpcs.filter((rpc) => rpc.input.oneofKind === "getMessages")).toHaveLength(1)
    await mh.until(() => {
      const row = mh.ui.rows(2).find((candidate) => candidate.kind === "message" && candidate.messageId === makeMessageId(id))
      const size = row?.kind === "message" && row.media?.kind === "photo" ? row.media.photo.sizes[0] : undefined
      return size?.cdnUrl === mh.transfers.fileUrl("photo-0-file")
    }, "row carries the fresh URL")
  })

  it("sign-out erases the account's cached media and upload jobs", async () => {
    const { mh, ids } = await boot(1)
    mh.ui.subscribeTo(10, { kind: "media", media: ref(ids[0]!) })
    await mh.until(() => mediaOf(mh.ui, 10)?.state === "ready", "ready")
    mh.transfers.fault({ method: 118 as never, kind: "hold-before", times: 100 })
    mh.intent("a", {
      kind: "attachFile",
      attachmentId: "a".repeat(24),
      file: new Blob([testBytes(2 * 512 * 1024) as Uint8Array<ArrayBuffer>]),
      fileName: "notes.bin",
      mimeType: "application/octet-stream",
    })
    await mh.final("a")
    expect((await mh.bytes.list(`accounts/u${self}/`)).length).toBeGreaterThan(0)
    mh.ui.post({ kind: "session", action: "signOut" })
    await mh.until(() => mh.ui.core(1)?.phase === "signedOut", "signed out")
    expect(await mh.bytes.list(`accounts/u${self}/`)).toEqual([])
    // The subscription stays, empty: the Blob it held is gone with the account.
    expect(mediaOf(mh.ui, 10)).toEqual({ kind: "media", state: "absent" })
  })

  it("warms nearby files from hints, within the auto-download limits, and refuses malformed hints", async () => {
    const { mh, ids } = await boot(1)
    mh.intent("h", { kind: "mediaHints", nearby: [ref(ids[0]!)] })
    expect((await mh.final("h")).status).toBe("confirmed")
    const media = (mh.host as unknown as { account: { media: { core: import("../../media").MediaCore } } }).account.media.core
    await mh.until(() => media.cache.has({ fileUniqueId: "photo-0-file", variant: "c" }), "warmed")
    mh.intent("bad", { kind: "mediaHints", nearby: [{ kind: "message" } as never] })
    expect(await mh.final("bad")).toMatchObject({ status: "rejected", reason: "invalid" })
  })

  it("answers a malformed media reference as an empty subscription", async () => {
    const { mh } = await boot(1)
    mh.ui.subscribeTo(10, { kind: "media", media: { kind: "message", chatId: chat, messageId: "x" as never } })
    await mh.synced()
    expect(mediaOf(mh.ui, 10)).toEqual({ kind: "media", state: "absent" })
  })
})
