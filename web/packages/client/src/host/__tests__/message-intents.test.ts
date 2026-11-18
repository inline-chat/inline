import { RpcError_Code, type ClientMessage } from "@inline-chat/protocol/core"
import {
  newClientKey,
  rowKey,
  sentMessageRowId,
  type Intent,
  type MessageRow,
} from "@inline/core-protocol"
import { chatId as makeChatId, messageId as makeMessageId } from "@inline/ids"
import { afterEach, describe, expect, it } from "vitest"
import type { OutgoingFrame } from "../../testing/server-model"
import { ModelHost } from "./model-host"

/**
 * `editText`, `deleteMessages` and `react` against the real host and the
 * server model. These intents are not replay-safe on the server: they need
 * a connection, are sent once, never enter the durable outbox, and settle
 * `uncertain` when the connection drops with them in flight.
 */

const chat = makeChatId(10)
const ADA = 2n

const running: ModelHost[] = []
afterEach(async () => {
  for (const host of running.splice(0)) await host.dispose()
})

const boot = async () => {
  const mh = new ModelHost()
  running.push(mh)
  mh.model.addUser(ADA, "Ada")
  mh.model.addChat({ id: 10n, title: "Design", participants: [ADA] })
  mh.model.postMessage({ chatId: 10n, fromId: ADA, text: "one" })
  mh.model.postMessage({ chatId: 10n, fromId: ADA, text: "two" })
  mh.model.postMessage({ chatId: 10n, fromId: mh.model.selfUserId, text: "mine" })
  await mh.seedDisk()
  await mh.start()
  mh.ui.subscribeTo(2, { kind: "chatWindow", chatId: chat, anchor: "latest" })
  await mh.until(() => mh.ui.list(2).length === 3, "window")
  await mh.synced()
  return mh
}

const rows = (mh: ModelHost) => mh.ui.rows(2) as MessageRow[]
const texts = (mh: ModelHost) => rows(mh).map((row) => row.text)
const serverText = (mh: ModelHost, id: bigint) =>
  mh.model.chatState(10n).messages.find((message) => message.id === id)?.text
const rpcCount = (mh: ModelHost, kind: string) =>
  mh.extraRpcs.filter((rpc) => rpc.input.oneofKind === kind).length

const edit = (id: number, text: string): Intent => ({
  kind: "editText",
  chatId: chat,
  messageId: makeMessageId(id),
  text,
})

const isResultOf = (kind: string) => (frame: OutgoingFrame) =>
  frame.kind === "result" &&
  frame.message.body.oneofKind === "rpcResult" &&
  frame.message.body.rpcResult.result.oneofKind === kind

const isCallOf = (kind: string) => (message: ClientMessage) =>
  message.body.oneofKind === "rpcCall" && message.body.rpcCall.input.oneofKind === kind

describe("editText", () => {
  it("shows the edit at once, then confirms it under the same row", async () => {
    const mh = await boot()
    mh.transport.hold()
    mh.intent("e1", edit(3, "mine, edited"))
    await mh.until(() => texts(mh).at(2) === "mine, edited", "optimistic edit")
    expect(mh.ui.result("e1")).toMatchObject({ status: "accepted" })
    await mh.settleUntil(mh.transport.release())
    expect((await mh.final("e1")).status).toBe("confirmed")
    expect(mh.results("e1")).toEqual(["accepted", "confirmed"])
    expect(texts(mh)).toEqual(["one", "two", "mine, edited"])
    expect(rows(mh)[2]!.editDate).toBeGreaterThan(0)
    expect(serverText(mh, 3n)).toBe("mine, edited")
    expect(mh.ui.result("e1")!.rows).toEqual([rowKey("message", `${chat}:3`)])
  })

  it("invariant 4: the display is recomputed from the confirmed base and ordered edits, never undone", async () => {
    const mh = await boot()
    // Hold every server frame, so both edits are open at once.
    mh.transport.hold()
    const start = mh.ui.patches.length
    mh.intent("e1", edit(3, "first"))
    mh.intent("e2", edit(3, "second"))
    await mh.until(() => texts(mh).at(2) === "second", "newest edit shows")
    // One edit of a message on the wire at a time, in order.
    expect(mh.transport.sent.filter(isCallOf("editMessage"))).toHaveLength(1)

    // The server refuses the second; the first lands.
    mh.fail = (input) =>
      input.oneofKind === "editMessage" && input.editMessage.text === "second"
        ? RpcError_Code.MESSAGE_ID_INVALID
        : undefined
    await mh.settleUntil(mh.transport.release())
    await mh.final("e1")
    await mh.until(() => mh.transport.sent.filter(isCallOf("editMessage")).length === 2, "second sent")
    await mh.final("e2")
    expect(mh.ui.result("e1")!.status).toBe("confirmed")
    expect(mh.ui.result("e2")).toMatchObject({ status: "rejected", reason: "server" })

    // Every text the row ever showed after the edits began: the newest open
    // edit, then the confirmed base. Never the text from before "first".
    const shown = mh.ui.patches
      .slice(start)
      .flatMap((patch) => patch.rows)
      .flatMap((change) =>
        change.op === "upsert" && change.row.kind === "message" && change.row.id === `${chat}:3`
          ? [change.row.text]
          : [],
      )
    expect(shown).toEqual(["second", "first"])
    expect(texts(mh).at(2)).toBe("first")
    expect(serverText(mh, 3n)).toBe("first")
  })

  it("is refused offline before anything shows", async () => {
    const mh = await boot()
    mh.ui.post({ kind: "signal", signal: { kind: "online", online: false } })
    await mh.until(() => mh.ui.core(1)?.connection === "waitingForNetwork", "offline")
    const before = mh.ui.patches.length
    mh.intent("e1", edit(3, "offline edit"))
    expect(await mh.final("e1")).toMatchObject({ status: "rejected", reason: "offline" })
    expect(texts(mh).at(2)).toBe("mine")
    expect(
      mh.ui.patches.slice(before).some((patch) => patch.rows.some((change) => change.op === "upsert")),
    ).toBe(false)
  })
})

describe("deleteMessages", () => {
  it("hides the rows at once, and they are gone after the server confirms", async () => {
    const mh = await boot()
    mh.intent("d1", { kind: "deleteMessages", chatId: chat, messageIds: [makeMessageId(1)] })
    await mh.until(() => mh.ui.list(2).length === 2, "hidden")
    expect((await mh.final("d1")).status).toBe("confirmed")
    await mh.synced()
    expect(texts(mh)).toEqual(["two", "mine"])
    expect(mh.model.chatState(10n).messages.map((message) => message.id)).toEqual([2n, 3n])
  })

  it("shows the message again when the server refuses", async () => {
    const mh = await boot()
    mh.fail = (input) =>
      input.oneofKind === "deleteMessages" ? RpcError_Code.MESSAGE_ID_INVALID : undefined
    mh.intent("d1", { kind: "deleteMessages", chatId: chat, messageIds: [makeMessageId(1)] })
    expect(await mh.final("d1")).toMatchObject({ status: "rejected", reason: "server" })
    await mh.until(() => mh.ui.list(2).length === 3, "visible again")
  })

  it("cancels a send that has not left the device: the server never sees it", async () => {
    const mh = await boot()
    mh.ui.post({ kind: "signal", signal: { kind: "online", online: false } })
    await mh.until(() => mh.ui.core(1)?.connection === "waitingForNetwork", "offline")
    const clientKey = newClientKey()
    mh.intent("s1", { kind: "sendText", chatId: chat, clientKey, text: "oops" })
    await mh.until(() => mh.ui.list(2).length === 4, "optimistic send")
    mh.intent("d1", { kind: "deleteMessages", chatId: chat, messageIds: [], clientKeys: [clientKey] })
    expect((await mh.final("d1")).status).toBe("confirmed")
    await mh.until(() => mh.ui.list(2).length === 3, "send removed")
    expect(await mh.final("s1")).toMatchObject({ status: "uncertain" })

    mh.ui.post({ kind: "signal", signal: { kind: "online", online: true } })
    await mh.until(() => mh.ui.core(1)?.connection === "connected", "online")
    await mh.synced()
    expect(mh.model.messagesWithRandomId(BigInt(clientKey))).toEqual([])
    expect(texts(mh)).toEqual(["one", "two", "mine"])
  })

  it("deletes a send already on the wire once it lands, never showing its server row", async () => {
    const mh = await boot()
    const clientKey = newClientKey()
    const sentRow = rowKey("message", sentMessageRowId(chat, clientKey))
    // The server takes the send, but its answer is held back.
    mh.transport.hold()
    mh.intent("s1", { kind: "sendText", chatId: chat, clientKey, text: "oops" })
    await mh.until(() => mh.transport.sent.some(isCallOf("sendMessage")), "send on the wire")
    await mh.until(() => mh.model.messagesWithRandomId(BigInt(clientKey)).length === 1, "server has it")
    mh.intent("d1", { kind: "deleteMessages", chatId: chat, messageIds: [], clientKeys: [clientKey] })
    await mh.until(() => !mh.ui.list(2).includes(sentRow), "hidden at once")
    expect(mh.ui.result("d1")).toMatchObject({ status: "accepted", rows: [sentRow] })

    await mh.settleUntil(mh.transport.release())
    expect((await mh.final("d1")).status).toBe("confirmed")
    await mh.synced()
    expect(mh.model.chatState(10n).messages.map((message) => message.text)).toEqual(["one", "two", "mine"])
    // After it was hidden, no patch listed the row again.
    const hiddenAt = mh.ui.patches.findIndex((patch) =>
      patch.settled.some((result) => result.tx === "d1" && result.status === "accepted"),
    )
    const relisted = mh.ui.patches.slice(hiddenAt + 1).some((patch) =>
      patch.lists.some((list) => (list.op === "replace" ? list.keys : list.insert).includes(sentRow)),
    )
    expect(relisted).toBe(false)
    expect(mh.ui.list(2)).not.toContain(sentRow)
  })
})

describe("react", () => {
  it("adds and removes a reaction with the optimistic count, out of the durable outbox", async () => {
    const mh = await boot()
    mh.transport.hold()
    mh.intent("r1", { kind: "react", chatId: chat, messageId: makeMessageId(1), emoji: "👍", action: "add" })
    await mh.until(() => rows(mh)[0]!.reactions?.[0]?.mine === true, "optimistic reaction")
    expect(mh.ui.result("r1")?.status).toBe("accepted")
    await mh.settleUntil(mh.transport.release())
    expect((await mh.final("r1")).status).toBe("confirmed")
    expect(rows(mh)[0]!.reactions).toEqual([{ emoji: "👍", count: 1, mine: true }])
    expect(await mh.disk.count("pending_transaction")).toBe(0)

    mh.intent("r2", { kind: "react", chatId: chat, messageId: makeMessageId(1), emoji: "👍", action: "remove" })
    expect((await mh.final("r2")).status).toBe("confirmed")
    await mh.until(() => rows(mh)[0]!.reactions == null, "reaction removed")
    expect(mh.model.chatState(10n).messages[0]!.reactions).toEqual([])
  })

  it("is refused offline", async () => {
    const mh = await boot()
    mh.ui.post({ kind: "signal", signal: { kind: "online", online: false } })
    await mh.until(() => mh.ui.core(1)?.connection === "waitingForNetwork", "offline")
    mh.intent("r1", { kind: "react", chatId: chat, messageId: makeMessageId(1), emoji: "👍", action: "add" })
    expect(await mh.final("r1")).toMatchObject({ status: "rejected", reason: "offline" })
    expect(rows(mh)[0]!.reactions).toBeUndefined()
  })
})

// ---------------------------------------------------------------------------
// Faults (the rows of docs/testing.md's matrix that apply to a request that
// is sent once): each intent under a lost acknowledgement, duplicated frames
// and a request lost on a dying connection.

type Case = {
  name: string
  kind: "editMessage" | "deleteMessages" | "addReaction"
  intent: Intent
  /** The server's state after the intent was applied once. */
  applied: (mh: ModelHost) => boolean
  /** The server's state when it never saw the intent. */
  untouched: (mh: ModelHost) => boolean
}

const cases: Case[] = [
  {
    name: "editText",
    kind: "editMessage",
    intent: edit(3, "edited under faults"),
    applied: (mh) => serverText(mh, 3n) === "edited under faults",
    untouched: (mh) => serverText(mh, 3n) === "mine",
  },
  {
    name: "deleteMessages",
    kind: "deleteMessages",
    intent: { kind: "deleteMessages", chatId: chat, messageIds: [makeMessageId(1)] },
    applied: (mh) => serverText(mh, 1n) === undefined,
    untouched: (mh) => serverText(mh, 1n) === "one",
  },
  {
    name: "react",
    kind: "addReaction",
    intent: { kind: "react", chatId: chat, messageId: makeMessageId(1), emoji: "🎉", action: "add" },
    applied: (mh) => mh.model.chatState(10n).messages[0]!.reactions.length === 1,
    untouched: (mh) => mh.model.chatState(10n).messages[0]!.reactions.length === 0,
  },
]

const reconnected = async (mh: ModelHost) => {
  await mh.until(() => mh.ui.core(1)?.connection === "connected", "reconnected")
  await mh.synced()
}

describe.each(cases)("$name under faults", (scenario) => {
  it("acknowledgement lost after the server applied: uncertain, applied once, never resent", async () => {
    const mh = await boot()
    let armed = true
    mh.endpoint.interceptor = (frame) => {
      if (armed && isResultOf(scenario.kind)(frame)) {
        armed = false
        return "drop-and-disconnect"
      }
      return "deliver"
    }
    mh.intent("t", scenario.intent)
    expect((await mh.final("t")).status).toBe("uncertain")
    await reconnected(mh)
    expect(scenario.applied(mh)).toBe(true)
    expect(rpcCount(mh, scenario.kind)).toBe(1)
    if (scenario.kind === "editMessage") {
      // Sync brings the server's edit; the display follows the base.
      await mh.until(() => texts(mh).at(2) === "edited under faults", "edit synced")
    }
    if (scenario.kind === "deleteMessages") {
      await mh.until(() => !texts(mh).includes("one"), "delete synced")
    }
  })

  it("every frame duplicated: confirmed once, applied once", async () => {
    const mh = await boot()
    mh.endpoint.interceptor = (frame) =>
      frame.kind === "push" || frame.kind === "result" ? "duplicate" : "deliver"
    mh.intent("t", scenario.intent)
    expect((await mh.final("t")).status).toBe("confirmed")
    await mh.synced()
    expect(mh.results("t")).toEqual(["accepted", "confirmed"])
    expect(scenario.applied(mh)).toBe(true)
    expect(rpcCount(mh, scenario.kind)).toBe(1)
  })

  it("request lost on a dying connection: uncertain, the server never sees it, the base shows", async () => {
    const mh = await boot()
    mh.transport.dropNextClientFrame(isCallOf(scenario.kind))
    mh.intent("t", scenario.intent)
    await mh.until(() => mh.ui.result("t")?.status === "accepted", "accepted")
    await mh.settleUntil(mh.transport.disconnect("request-lost"))
    expect((await mh.final("t")).status).toBe("uncertain")
    await reconnected(mh)
    expect(scenario.untouched(mh)).toBe(true)
    expect(rpcCount(mh, scenario.kind)).toBe(0)
    // Nothing optimistic is left over.
    expect(texts(mh)).toEqual(["one", "two", "mine"])
    expect(rows(mh)[0]!.reactions).toBeUndefined()
  })
})

describe("bot buttons and forms", () => {
  const answerLater = (mh: ModelHost, text: string) => {
    mh.onAction = (interactionId) => {
      setTimeout(() => {
        void mh.transport.pushUpdates([
          {
            update: {
              oneofKind: "messageActionAnswered",
              messageActionAnswered: {
                interactionId,
                ui: { kind: { oneofKind: "toast", toast: { text } } },
              },
            },
          } as never,
        ])
      }, 500)
    }
  }

  it("invokes a button and confirms with the bot's answer", async () => {
    const mh = await boot()
    answerLater(mh, "Approved")
    mh.intent("b1", { kind: "invokeAction", chatId: chat, messageId: makeMessageId(1), actionId: "approve" })
    const final = await mh.final("b1")
    expect(mh.results("b1")).toEqual(["accepted", "confirmed"])
    expect(final.answer).toEqual({ kind: "toast", text: "Approved" })
    const call = mh.extraRpcs.find((rpc) => rpc.input.oneofKind === "invokeMessageAction")!
    expect(call.input).toMatchObject({
      invokeMessageAction: { messageId: 1n, actionId: "approve" },
    })
  })

  it("confirms without an answer when the bot stays silent", async () => {
    const mh = await boot()
    mh.intent("b1", { kind: "invokeAction", chatId: chat, messageId: makeMessageId(1), actionId: "noop" })
    const final = await mh.final("b1")
    expect(final.status).toBe("confirmed")
    expect(final.answer).toBeUndefined()
  })

  it("submits a form's values under its form ID", async () => {
    const mh = await boot()
    answerLater(mh, "Thanks")
    mh.intent("f1", {
      kind: "submitForm",
      chatId: chat,
      messageId: makeMessageId(2),
      formId: "survey",
      values: [
        { fieldId: "name", value: { kind: "text", text: "Ada" } },
        { fieldId: "size", value: { kind: "selection", optionIds: ["m"], otherText: "roomy" } },
        { fieldId: "ok", value: { kind: "toggle", value: false } },
        { fieldId: "count", value: { kind: "number", value: 3 } },
      ],
    })
    expect((await mh.final("f1")).answer).toEqual({ kind: "toast", text: "Thanks" })
    const call = mh.extraRpcs.find((rpc) => rpc.input.oneofKind === "invokeMessageAction")!
    expect(call.input).toMatchObject({
      invokeMessageAction: {
        messageId: 2n,
        actionId: "survey",
        form: {
          values: [
            { fieldId: "name", value: { oneofKind: "text", text: "Ada" } },
            { fieldId: "size", value: { oneofKind: "selection", selection: { optionIds: ["m"], otherText: "roomy" } } },
            { fieldId: "ok", value: { oneofKind: "toggle", toggle: false } },
            { fieldId: "count", value: { oneofKind: "number", number: 3 } },
          ],
        },
      },
    })
  })

  it("rejects a malformed form and any action offline, as data", async () => {
    const mh = await boot()
    mh.intent("f1", {
      kind: "submitForm",
      chatId: chat,
      messageId: makeMessageId(2),
      formId: "survey",
      values: [{ fieldId: "x", value: { kind: "number", value: Number.NaN } }],
    })
    expect(await mh.final("f1")).toMatchObject({ status: "rejected", reason: "invalid" })
    mh.ui.post({ kind: "signal", signal: { kind: "online", online: false } })
    await mh.until(() => mh.ui.core(1)?.connection === "waitingForNetwork", "offline")
    mh.intent("b1", { kind: "invokeAction", chatId: chat, messageId: makeMessageId(1), actionId: "approve" })
    expect(await mh.final("b1")).toMatchObject({ status: "rejected", reason: "offline" })
    expect(mh.extraRpcs).toEqual([])
  })
})
