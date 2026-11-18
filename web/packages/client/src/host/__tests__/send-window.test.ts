import { RpcError_Code } from "@inline-chat/protocol/core"
import type { AttachmentId, MessageRow, Patch, RowKey } from "@inline/core-protocol"
import { newClientKey, receivedMessageRowId, rowKey, sentMessageRowId } from "@inline/core-protocol"
import { chatId as makeChatId, messageId as makeMessageId } from "@inline/ids"
import { afterEach, describe, expect, it } from "vitest"
import { MediaModelHost } from "./media-host"
import { ModelHost } from "./model-host"

/**
 * A send in an open chat window, recorded patch by patch (the list a view
 * store holds after each patch). The rule the timeline relies on: a send
 * appears in one frame and nothing else moves. So, for a window at latest,
 * every patch that touches the window's list only ever adds the send's row
 * (an optimistic row confirmed under the same key is not a removal), and no
 * patch repeats the list it already had.
 */

const chat = makeChatId(10)
const SUB = 2
const PAGE = 20

const running: ModelHost[] = []
afterEach(async () => {
  for (const host of running.splice(0)) await host.dispose()
})

/** 100 messages on the server; the window is opened at latest and paged back twice (60 rows). */
const boot = async (options: { pages?: number; media?: boolean } = {}) => {
  const mh = options.media
    ? new MediaModelHost({ host: { pageSize: PAGE } })
    : new ModelHost({ host: { pageSize: PAGE } })
  running.push(mh)
  mh.model.addUser(2n, "Ada")
  mh.model.addChat({ id: 10n, title: "Design", participants: [2n] })
  for (let index = 1; index <= 100; index += 1) {
    mh.model.postMessage({ chatId: 10n, fromId: 2n, text: `m${index}` })
  }
  await mh.seedDisk()
  await mh.start()
  mh.ui.subscribeTo(SUB, { kind: "chatWindow", chatId: chat, anchor: "latest" })
  await mh.until(() => mh.ui.list(SUB).length === PAGE, "latest page")
  await mh.synced()
  for (let page = 1; page <= (options.pages ?? 2); page += 1) {
    mh.ui.post({ kind: "ensure", sub: SUB, range: "older" })
    await mh.until(() => mh.ui.list(SUB).length === PAGE * (page + 1), `older page ${page}`)
    await mh.synced()
  }
  return mh
}

type Recorded = { lists: RowKey[][]; patches: Patch[] }

/** Record the window's list after every patch that changes it. */
const record = (mh: ModelHost): Recorded & { stop: () => void } => {
  const recorded: Recorded = { lists: [mh.ui.list(SUB).slice()], patches: [] }
  const stop = mh.ui.observe((patch) => {
    if (!patch.lists.some((change) => change.sub === SUB)) return
    recorded.patches.push(patch)
    recorded.lists.push(mh.ui.list(SUB).slice())
  })
  return { ...recorded, stop }
}

const texts = (mh: ModelHost) =>
  mh.ui.rows(SUB).flatMap((row) => (row.kind === "message" ? [(row as MessageRow).text] : []))

/**
 * Every step keeps every key it had and adds only keys in `allowed`; no step
 * repeats the previous list.
 */
const expectOnlyGains = (lists: RowKey[][], allowed: ReadonlySet<RowKey>) => {
  for (let index = 1; index < lists.length; index += 1) {
    const before = lists[index - 1]!
    const after = lists[index]!
    const removed = before.filter((key) => !after.includes(key))
    const added = after.filter((key) => !before.includes(key))
    expect({ step: index, removed }).toEqual({ step: index, removed: [] })
    expect({ step: index, unexpected: added.filter((key) => !allowed.has(key)) }).toEqual({
      step: index,
      unexpected: [],
    })
    expect({ step: index, repeated: after.join() === before.join() }).toEqual({ step: index, repeated: false })
  }
}

const send = (mh: ModelHost, text: string, tx = "send") => {
  const clientKey = newClientKey()
  mh.intent(tx, { kind: "sendText", chatId: chat, clientKey, text })
  return sentKey(clientKey)
}

const sentKey = (clientKey: string) => rowKey("message", sentMessageRowId(chat, clientKey))
const messageKey = (id: number) => rowKey("message", receivedMessageRowId(chat, makeMessageId(id)))

describe("a send in an open window", () => {
  it("at latest with older pages: the list only gains the send, through accept and confirm", async () => {
    const mh = await boot()
    expect(texts(mh).at(0)).toBe("m41")
    const recording = record(mh)

    const key = send(mh, "hello")
    expect((await mh.final("send")).status).toBe("confirmed")
    await mh.synced()
    recording.stop()

    expect(mh.ui.list(SUB)).toHaveLength(61)
    expect(mh.ui.list(SUB).at(-1)).toBe(key)
    expect(texts(mh).at(0)).toBe("m41")
    expectOnlyGains(recording.lists, new Set([key]))
    // The send arrives in one patch, as the last row.
    expect(recording.lists[1]).toEqual([...recording.lists[0]!, key])
  })

  it("racing an incoming message: the list gains the send and the incoming row only", async () => {
    const mh = await boot()
    const recording = record(mh)

    const key = send(mh, "mine")
    mh.model.postMessage({ chatId: 10n, fromId: 2n, text: "theirs" })
    expect((await mh.final("send")).status).toBe("confirmed")
    await mh.synced()
    recording.stop()

    expectOnlyGains(recording.lists, new Set([key, messageKey(101), messageKey(102)]))
    expect(texts(mh).slice(-2).sort()).toEqual(["mine", "theirs"])
    expect(mh.ui.list(SUB)).toHaveLength(62)
  })

  it("rejected: the row stays, failed, and nothing else moves", async () => {
    const mh = await boot()
    mh.fail = (input) => (input.oneofKind === "sendMessage" ? RpcError_Code.BAD_REQUEST : undefined)
    const recording = record(mh)

    const key = send(mh, "refused")
    expect((await mh.final("send")).status).toBe("rejected")
    await mh.synced()
    recording.stop()

    expectOnlyGains(recording.lists, new Set([key]))
    expect(mh.ui.list(SUB).at(-1)).toBe(key)
    expect(mh.ui.list(SUB)).toHaveLength(61)
  })

  it("acknowledged after a reconnect: the list only gains the send", async () => {
    const mh = await boot()
    const recording = record(mh)

    // The request reaches the server; its answer is lost with the connection.
    mh.endpoint.interceptor = (frame) => {
      const body = frame.message.body
      return body.oneofKind === "rpcResult" && body.rpcResult.result.oneofKind === "sendMessage"
        ? "drop-and-disconnect"
        : "deliver"
    }
    const key = send(mh, "through a reconnect")
    await mh.until(() => mh.model.chatState(10n).messages.some((message) => message.text === "through a reconnect"), "server applied")
    mh.endpoint.interceptor = () => "deliver"
    expect((await mh.final("send")).status).toBe("confirmed")
    await mh.synced()
    recording.stop()

    expectOnlyGains(recording.lists, new Set([key]))
    expect(mh.ui.list(SUB).at(-1)).toBe(key)
    expect(mh.ui.list(SUB)).toHaveLength(61)
  })

  it("a media send: the list only gains the send, through upload and confirm", async () => {
    const mh = await boot({ media: true })
    const attachmentId = "0000000000000000000000a1" as AttachmentId
    mh.intent("attach", {
      kind: "attachFile",
      attachmentId,
      file: new Blob([new Uint8Array(64)], { type: "application/pdf" }),
      fileName: "spec.pdf",
      mimeType: "application/pdf",
    })
    expect((await mh.final("attach")).status).toBe("confirmed")
    await mh.synced()
    const recording = record(mh)

    const clientKey = newClientKey()
    mh.intent("media", { kind: "sendMedia", chatId: chat, clientKey, attachmentId })
    expect((await mh.final("media")).status).toBe("confirmed")
    await mh.synced()
    recording.stop()

    const key = sentKey(clientKey)
    expectOnlyGains(recording.lists, new Set([key]))
    expect(mh.ui.list(SUB).at(-1)).toBe(key)
    expect(mh.ui.list(SUB)).toHaveLength(61)
  })

  it("anchored in older history: the window moves to latest in one step, never through a partial list", async () => {
    const mh = await boot({ pages: 0 })
    // Jump to message 30, far from latest: the window is [~20..~40], not at latest.
    mh.ui.post({ kind: "ensure", sub: SUB, range: { around: makeMessageId(30) } })
    await mh.until(() => texts(mh).includes("m30") && !texts(mh).includes("m100"), "around 30")
    await mh.synced()
    expect(mh.ui.window(SUB)?.atLatest).toBe(false)
    const recording = record(mh)

    const key = send(mh, "from history")
    expect((await mh.final("send")).status).toBe("confirmed")
    await mh.synced()
    recording.stop()

    expect(mh.ui.window(SUB)?.atLatest).toBe(true)
    expect(mh.ui.list(SUB).at(-1)).toBe(key)
    expect(texts(mh)).toContain("m100")
    // Every step either keeps all it had (gains only) or is the one jump to
    // latest, which already holds the send and the latest rows.
    const lists = recording.lists
    let jumps = 0
    for (let index = 1; index < lists.length; index += 1) {
      const before = lists[index - 1]!
      const after = lists[index]!
      expect(after.join()).not.toBe(before.join())
      if (before.every((key) => after.includes(key))) continue
      jumps += 1
      expect(after).toContain(key)
      expect(after).toContain(messageKey(100))
    }
    expect(jumps).toBe(1)
  })
})
