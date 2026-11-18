import { describe, expect, it } from "vitest"
import type { Command, Intent, MessageRow } from "@inline/core-protocol"
import { rowKeyOf, sentMessageRowId } from "@inline/core-protocol"
import { message } from "@inline/reactive/testing"
import { ChatModel, predictReactions } from "./chat-model"
import { IntentTracker } from "./intent-outcome"
import { canDeleteMessage, canEditMessage, messageAbilities } from "./message-abilities"
import { chatRow, cid, harness, keys, mid, uid, upserts, windowResource } from "./test-support"

const me = uid(9)
const other = uid(4)

const mine = (id: number, text: string, extra: Partial<MessageRow> = {}) =>
  message(5, id, text, { fromId: me, out: true, ...extra })
const theirs = (id: number, text: string, extra: Partial<MessageRow> = {}) => message(5, id, text, { fromId: other, ...extra })

/** A send from this device: keyed by client key, with or without a server ID. */
const sent = (clientKey: string, state: MessageRow["state"], messageId?: number): MessageRow => ({
  kind: "message",
  id: sentMessageRowId(cid(5), clientKey),
  chatId: cid(5),
  clientKey,
  ...(messageId !== undefined ? { messageId: mid(messageId) } : {}),
  fromId: me,
  out: true,
  date: 1_800_000_000,
  text: `send ${clientKey}`,
  state,
})

const setup = (options: { tracker?: boolean } = {}) => {
  const h = harness()
  const posted: Command[] = []
  const tracker = options.tracker === false ? undefined : new IntentTracker({ core: h.endpoint, store: h.client.store })
  const model = new ChatModel({
    client: h.client,
    chatId: cid(5),
    userId: me,
    clock: h.time,
    now: () => 1_800_000_500_000,
    random: () => 0.5,
    newClientKey: () => "100",
    ...(tracker ? { intents: tracker } : {}),
    post: (command) => {
      posted.push(command)
      h.endpoint.post(command)
    },
  })
  const release = model.retain()
  const windowSub = h.sub((query) => query.kind === "chatWindow")
  const history: MessageRow[] = [
    theirs(1, "hi", { reactions: [{ emoji: "👍", count: 1, mine: false }] }),
    mine(2, "hello there"),
    theirs(3, "how are you"),
    sent("70", "sent", 4),
    sent("71", "sending"),
    sent("72", "failed"),
  ]
  const openWindow = async (resource = windowResource()) => {
    h.endpoint.patch({
      rows: upserts(...history, chatRow(5, { title: "Ops" })),
      lists: [{ sub: windowSub, op: "replace", keys: keys(...history) }],
      resources: [{ sub: windowSub, value: resource }],
    })
    await h.flush()
  }
  const lastIntent = () => {
    const command = h.endpoint.commands("intent").at(-1)!
    return { tx: command.tx, intent: command.intent }
  }
  return { ...h, model, release, windowSub, history, openWindow, lastIntent, posted, tracker }
}

const keyOf = (row: MessageRow) => rowKeyOf(row)

describe("ChatModel actions", () => {
  it("edits: the text shows in the same task, then acceptance and confirmation", async () => {
    const s = setup()
    await s.openWindow()
    const key = keyOf(s.history[1]!)
    const handle = s.model.edit(mid(2), "hello again", [{ type: "bold", offset: 0, length: 5 }])
    expect(s.lastIntent().intent).toEqual({
      kind: "editText",
      chatId: cid(5),
      messageId: mid(2),
      text: "hello again",
      entities: [{ type: "bold", offset: 0, length: 5 }],
    })
    // Predicted in the overlay before any frame.
    expect(s.model.row(key).peek()).toMatchObject({ text: "hello again", editDate: 1_800_000_500 })

    const tx = handle.tx
    const shown = { ...s.history[1]!, text: "hello again", editDate: 1_800_000_501 }
    s.endpoint.patch({ rows: upserts(shown), settled: [{ tx, status: "accepted" }] })
    await s.flush()
    expect(await handle).toEqual({ status: "accepted", tx })
    // The core's row replaced the prediction.
    expect(s.model.row(key).peek()).toMatchObject({ text: "hello again", editDate: 1_800_000_501 })

    s.endpoint.patch({ settled: [{ tx, status: "confirmed" }] })
    await s.flush()
    expect(await handle.outcome).toEqual({ status: "confirmed", tx })
    expect(s.tracker!.size).toBe(0)
  })

  it("an edit refused offline restores the row and says why", async () => {
    const s = setup()
    await s.openWindow()
    const key = keyOf(s.history[1]!)
    const handle = s.model.edit(mid(2), "never")
    expect(s.model.row(key).peek()?.text).toBe("never")
    s.endpoint.patch({ settled: [{ tx: handle.tx, status: "rejected", reason: "offline" }] })
    await s.flush()
    const result = await handle
    expect(result).toMatchObject({ status: "rejected", reason: "offline", retryable: true, notice: { kind: "offline", tone: "error" } })
    expect(s.model.row(key).peek()?.text).toBe("hello there")
    expect(await handle.outcome).toEqual(result)
  })

  it("an edit that settles uncertain is reported as neither failed nor done", async () => {
    const s = setup()
    await s.openWindow()
    const handle = s.model.edit(mid(2), "maybe")
    s.endpoint.patch({ settled: [{ tx: handle.tx, status: "accepted" }] })
    await s.flush()
    expect((await handle).status).toBe("accepted")
    s.endpoint.patch({ settled: [{ tx: handle.tx, status: "uncertain" }] })
    await s.flush()
    const outcome = await handle.outcome
    expect(outcome).toMatchObject({ status: "uncertain", notice: { kind: "uncertain", tone: "warning", title: "Not confirmed yet" } })
  })

  it("follows an outcome that arrives in the same frame as the acceptance", async () => {
    const s = setup()
    await s.openWindow()
    const handle = s.model.react(mid(3), "🔥")
    // Two patches delivered before the frame applies them.
    s.endpoint.patch({ settled: [{ tx: handle.tx, status: "accepted" }] })
    s.endpoint.patch({ settled: [{ tx: handle.tx, status: "rejected", reason: "server" }] })
    await s.flush()
    expect((await handle).status).toBe("accepted")
    expect(await handle.outcome).toMatchObject({
      status: "rejected",
      reason: "server",
      retryable: false,
      notice: { kind: "refused", title: "Couldn't add the reaction", text: "The server refused it." },
    })
  })

  it("maps storage full and an unavailable core onto notices", async () => {
    const s = setup()
    await s.openWindow()
    const full = s.model.unreact(mid(1), "👍")
    s.endpoint.patch({ settled: [{ tx: full.tx, status: "rejected", reason: "storageFull" }] })
    const gone = s.model.invokeAction(mid(3), "a1")
    s.endpoint.patch({ settled: [{ tx: gone.tx, status: "rejected", reason: "unavailable" }] })
    await s.flush()
    expect(await full).toMatchObject({ reason: "storageFull", retryable: true, notice: { kind: "storageFull" } })
    expect(await gone).toMatchObject({ reason: "unavailable", retryable: true, notice: { kind: "unavailable" } })
  })

  it("deletes a sent message by ID and a failed send by client key", async () => {
    const s = setup()
    await s.openWindow()
    const handle = s.model.deleteRows([keyOf(s.history[2]!), keyOf(s.history[5]!), keyOf(s.history[3]!)])
    expect(s.lastIntent().intent).toEqual({
      kind: "deleteMessages",
      chatId: cid(5),
      messageIds: [mid(3), mid(4)],
      clientKeys: ["72"],
    })
    // Nothing predicted: the rows go with the core's patch.
    expect(s.model.rowKeys.peek()).toHaveLength(6)
    s.endpoint.patch({
      lists: [{ sub: s.windowSub, op: "replace", keys: keys(...s.history.slice(0, 2), s.history[4]!) }],
      settled: [{ tx: handle.tx, status: "accepted" }],
    })
    await s.flush()
    expect((await handle).status).toBe("accepted")
    expect(s.model.rowKeys.peek()).toHaveLength(3)
  })

  it("deleting a message that is still sending cancels it by client key", async () => {
    const s = setup()
    await s.openWindow()
    const sending = s.history[4]!
    const handle = s.model.deleteRows([keyOf(sending)])
    expect(s.lastIntent().intent).toEqual({ kind: "deleteMessages", chatId: cid(5), messageIds: [], clientKeys: ["71"] })
    s.endpoint.patch({ settled: [{ tx: handle.tx, status: "rejected", reason: "server" }] })
    await s.flush()
    expect(await handle).toMatchObject({ notice: { title: "Couldn't cancel the message" } })

    // A send just made here can be cancelled at once.
    const send = s.model.send("oops", [], undefined)
    const cancel = s.model.deleteRows([send.rowKey])
    expect(s.lastIntent().intent).toEqual({ kind: "deleteMessages", chatId: cid(5), messageIds: [], clientKeys: ["100"] })
    expect(cancel.tx).not.toBe(send.tx)
  })

  it("predicts reactions in the same task, as the core summarizes them", async () => {
    const s = setup()
    await s.openWindow()
    const key = keyOf(s.history[0]!)
    s.model.toggleReaction(mid(1), "👍")
    expect(s.lastIntent().intent).toEqual({ kind: "react", chatId: cid(5), messageId: mid(1), emoji: "👍", action: "add" })
    expect(s.model.row(key).peek()?.reactions).toEqual([{ emoji: "👍", count: 2, mine: true }])
    s.model.react(mid(1), "🎉")
    expect(s.model.row(key).peek()?.reactions).toEqual([
      { emoji: "👍", count: 2, mine: true },
      { emoji: "🎉", count: 1, mine: true },
    ])
    s.model.toggleReaction(mid(1), "🎉")
    expect((s.lastIntent().intent as Extract<Intent, { kind: "react" }>).action).toBe("remove")
    expect(s.model.row(key).peek()?.reactions).toEqual([{ emoji: "👍", count: 2, mine: true }])
  })

  it("reacts to a send from this device found by its server ID", async () => {
    const s = setup()
    await s.openWindow()
    s.model.react(mid(4), "👀")
    expect(s.model.row(keyOf(s.history[3]!)).peek()?.reactions).toEqual([{ emoji: "👀", count: 1, mine: true }])
  })

  it("presses a bot button and submits a form, carrying the bot's answer", async () => {
    const s = setup()
    await s.openWindow()
    const press = s.model.invokeAction(mid(3), "approve")
    expect(s.lastIntent().intent).toEqual({ kind: "invokeAction", chatId: cid(5), messageId: mid(3), actionId: "approve" })
    s.endpoint.patch({ settled: [{ tx: press.tx, status: "accepted" }] })
    await s.flush()
    s.endpoint.patch({ settled: [{ tx: press.tx, status: "confirmed", answer: { kind: "toast", text: "Approved" } }] })
    await s.flush()
    expect(await press.outcome).toEqual({ status: "confirmed", tx: press.tx, answer: { kind: "toast", text: "Approved" } })

    s.model.submitForm(mid(3), "f1", [{ fieldId: "name", value: { kind: "text", text: "Ada" } }])
    expect(s.lastIntent().intent).toEqual({
      kind: "submitForm",
      chatId: cid(5),
      messageId: mid(3),
      formId: "f1",
      values: [{ fieldId: "name", value: { kind: "text", text: "Ada" } }],
    })
  })

  it("resends a failed send with its client key", async () => {
    const s = setup()
    await s.openWindow()
    s.model.resend(keyOf(s.history[5]!))
    expect(s.lastIntent().intent).toEqual({ kind: "retrySend", chatId: cid(5), clientKey: "72" })
  })

  it("edits from the composer and keeps the text on refusal", async () => {
    const s = setup()
    await s.openWindow()
    const outcome = s.model.sendFromComposer({ kind: "edit", text: "fixed", entities: [], revision: 3, edit: { messageId: mid(2) } })
    expect(s.lastIntent().intent).toMatchObject({ kind: "editText", messageId: mid(2), text: "fixed" })
    s.endpoint.patch({ settled: [{ tx: s.lastIntent().tx, status: "rejected", reason: "offline" }] })
    await s.flush()
    expect(await outcome).toEqual({ status: "rejected", reason: "offline" })
    expect(await s.model.sendFromComposer({ kind: "edit", text: "x", entities: [], revision: 4 })).toEqual({
      status: "rejected",
      reason: "invalid",
    })
  })

  it("without a tracker, an outcome is the next result the store delivers", async () => {
    const s = setup({ tracker: false })
    await s.openWindow()
    const handle = s.model.edit(mid(2), "plain")
    s.endpoint.patch({ settled: [{ tx: handle.tx, status: "accepted" }] })
    await s.flush()
    await handle
    s.endpoint.patch({ settled: [{ tx: handle.tx, status: "confirmed" }] })
    await s.flush()
    expect((await handle.outcome).status).toBe("confirmed")
  })

  it("says what the viewer can do with each message, and which is the last editable", async () => {
    const s = setup()
    await s.openWindow()
    expect(s.model.abilities(keyOf(s.history[1]!))).toMatchObject({ edit: true, delete: true, reply: true, react: true })
    expect(s.model.abilities(keyOf(s.history[2]!))).toMatchObject({ edit: false, delete: true, reply: true })
    expect(s.model.abilities(keyOf(s.history[4]!))).toMatchObject({ edit: false, delete: false, cancel: true, react: false })
    expect(s.model.abilities(keyOf(s.history[5]!))).toMatchObject({ delete: true, resend: true, reply: false })
    expect(s.model.lastEditableMessageId()).toBe(mid(4))
  })
})

describe("ChatModel window discipline", () => {
  it("forwards a trim with the window's sub and the kept range, once per range", async () => {
    const s = setup()
    await s.openWindow()
    expect(s.model.trimWindow({ from: mid(2), to: mid(4) })).toBe(true)
    expect(s.posted).toEqual([{ kind: "trimWindow", sub: s.windowSub, keep: { from: mid(2), to: mid(4) } }])
    // The same range again is not sent.
    expect(s.model.trimWindow({ from: mid(2), to: mid(4) })).toBe(false)
    expect(s.posted).toHaveLength(1)
    // A range keeping the whole window releases nothing.
    expect(s.model.trimWindow({ from: mid(1), to: mid(4) })).toBe(false)
    // A reversed range is ignored.
    expect(s.model.trimWindow({ from: mid(4), to: mid(2) })).toBe(false)
    // After the window moves, the same range may release rows again.
    s.model.ensureOlder()
    expect(s.model.trimWindow({ from: mid(2), to: mid(4) })).toBe(true)
    expect(s.posted).toHaveLength(2)
  })

  it("trims to the rows the timeline keeps, by their server IDs", async () => {
    const s = setup()
    await s.openWindow()
    // The rendered range: from message 3 to the sends at the end (which have no ID).
    expect(s.model.trimToRows(keys(...s.history.slice(2)))).toBe(true)
    expect(s.posted.at(-1)).toEqual({ kind: "trimWindow", sub: s.windowSub, keep: { from: mid(3), to: mid(4) } })
    expect(s.model.trimToRows(keys(s.history[4]!))).toBe(false)
  })

  it("exposes certifiedThrough and never marks read past it", async () => {
    const s = setup()
    await s.openWindow(windowResource({ certifiedThrough: mid(3) }))
    expect(s.model.window.peek().certifiedThrough).toBe(mid(3))
    s.model.markRead(mid(10))
    const read = s.endpoint.commands("intent").filter((command) => command.intent.kind === "markRead")
    expect(read.map((command) => (command.intent as Extract<Intent, { kind: "markRead" }>).maxId)).toEqual([mid(3)])
  })

  it("marks read freely when the core has not certified anything", async () => {
    const s = setup()
    await s.openWindow()
    expect(s.model.window.peek().certifiedThrough).toBeUndefined()
    s.model.markRead(mid(10))
    expect(s.lastIntent().intent).toEqual({ kind: "markRead", chatId: cid(5), maxId: mid(10) })
  })
})

describe("message abilities", () => {
  const viewer = me
  it("follows the Mac menu's rules", () => {
    expect(canEditMessage(mine(2, "x"), viewer)).toBe(true)
    expect(canEditMessage(mine(2, "x", { service: { kind: "pinnedMessage" } as never }), viewer)).toBe(false)
    expect(canEditMessage(theirs(2, "x"), viewer)).toBe(false)
    expect(canEditMessage(sent("1", "sending"), viewer)).toBe(false)
    expect(canDeleteMessage(theirs(2, "x"))).toBe(true)
    expect(canDeleteMessage(sent("1", "sending"))).toBe(false)
    expect(canDeleteMessage(sent("1", "uncertain"))).toBe(true)
    expect(messageAbilities(mine(2, "  "), viewer).copyText).toBe(false)
  })

  it("predicts reaction summaries without changing what is already true", () => {
    const base = [{ emoji: "👍", count: 2, mine: false }]
    expect(predictReactions(base, "👍", "add")).toEqual([{ emoji: "👍", count: 3, mine: true }])
    expect(predictReactions(base, "👍", "remove")).toBe(base)
    expect(predictReactions([{ emoji: "👍", count: 1, mine: true }], "👍", "remove")).toEqual([])
    expect(predictReactions(undefined, "👍", "add")).toEqual([{ emoji: "👍", count: 1, mine: true }])
  })
})
