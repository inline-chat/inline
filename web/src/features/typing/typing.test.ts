import type { ChatRow, ComposeActionKind, ComposeActivity, UserRow } from "@inline/core-protocol"
import { COMPOSE_ACTION_RULE } from "@inline/core-protocol"
import { chatId as toChatId, userId as toUserId } from "@inline/ids"
import { effect, manualTime, signal } from "@inline/reactive"
import { afterEach, describe, expect, it } from "vitest"
import { testHarness, type TestHarness } from "../chat-info/testing"
import { createComposeReporter } from "./outgoing"
import { composeStatus, typingText } from "./presentation"
import { createChatTyping, createComposeActivityIndex } from "./typing-model"

/** A name as it appears inside a typing sentence: isolated for bidirectional text. */
const N = (name: string) => `\u2068${name}\u2069`

const me = toUserId("1")
const uid = (n: number) => toUserId(String(n))
const cid = (n: number) => toChatId(String(n))

const user = (n: number, firstName: string, lastName?: string): UserRow => ({
  kind: "user",
  id: uid(n),
  firstName,
  ...(lastName ? { lastName } : {}),
})

const people: UserRow[] = [
  user(2, "Ada", "Lovelace"),
  user(3, "Alan", "Turing"),
  user(4, "Grace", "Hopper"),
  user(5, "مریم", "میرزاخانی"),
  user(6, "Edsger"),
]

const thread: ChatRow = { kind: "chat", id: cid(100), title: "Launch" }
const direct: ChatRow = { kind: "chat", id: cid(200), peerUserId: uid(2) }

const typing = (chat: number, userN: number, action: ComposeActionKind = "typing"): ComposeActivity => ({
  chatId: cid(chat),
  userId: uid(userN),
  action,
})

let h: TestHarness | undefined
afterEach(() => {
  h?.dispose()
  h = undefined
})

const setup = async () => {
  h = testHarness({ me })
  h.core.setUsers(people)
  h.core.setChat(thread)
  h.core.setChat(direct)
  // The chat rows reach the store through the chat window or the sidebar in the app.
  h.client.subscribe({ kind: "chat", chatId: thread.id })
  h.client.subscribe({ kind: "chat", chatId: direct.id })
  await h.flush()
  return h
}

describe("typing wording (Mac ComposeActions)", () => {
  it("names one, two, three and many people in a thread", () => {
    expect(typingText([], false)).toBeUndefined()
    expect(typingText(["Ada"], false)).toBe(`${N("Ada")} is typing`)
    expect(typingText(["Ada", "Alan"], false)).toBe(`${N("Ada")} and ${N("Alan")} are typing`)
    expect(typingText(["Ada", "Alan", "Grace"], false)).toBe(`${N("Ada")}, ${N("Alan")} and ${N("Grace")} are typing`)
    expect(typingText(["Ada", "Alan", "Grace", "Edsger"], false)).toBe(`${N("Ada")}, ${N("Alan")} and 2 others are typing`)
  })

  it("uses the short form for rows and just 'typing' in a direct message", () => {
    expect(typingText(["Ada", "Alan", "Grace"], false, "short")).toBe(`${N("Ada")} and 2 others are typing`)
    expect(typingText(["Ada", "Alan"], false, "short")).toBe(`${N("Ada")} and ${N("Alan")} are typing`)
    expect(typingText(["Ada"], true)).toBe("typing")
  })

  it("puts typing before other activity, and names the person doing it by first name in a thread", () => {
    const rows = new Map(people.map((row) => [row.id, row]))
    const lookup = (id: string) => rows.get(id as never)
    expect(
      composeStatus({ activities: [typing(100, 3, "uploadingPhoto"), typing(100, 2)], isDirect: false, user: lookup }),
    ).toEqual({ kind: "typing", text: `${N("Ada Lovelace")} is typing` })
    expect(composeStatus({ activities: [typing(100, 3, "uploadingPhoto")], isDirect: false, user: lookup })).toEqual({
      kind: "sending",
      media: "photo",
      text: `${N("Alan")} is sending photo`,
    })
    expect(composeStatus({ activities: [typing(200, 2, "uploadingVideo")], isDirect: true, user: lookup })).toEqual({
      kind: "sending",
      media: "video",
      text: "sending video",
    })
    expect(composeStatus({ activities: [typing(100, 2, "recordingVoice"), typing(100, 3, "uploadingDocument")], isDirect: false, user: lookup })).toEqual({
      kind: "recording",
      text: `${N("Ada")} is recording voice`,
    })
    expect(composeStatus({ activities: [typing(100, 9, "working")], isDirect: false, user: lookup })).toEqual({ kind: "working", text: "Working" })
    // Someone whose row is missing is left out, as on the Mac.
    expect(composeStatus({ activities: [typing(100, 99)], isDirect: false, user: lookup })).toBeUndefined()
  })
})

describe("ChatTypingModel", () => {
  it("shows one, two and many people from the core's compose resource, and clears when the core expires them", async () => {
    const t = await setup()
    const model = createChatTyping({ client: t.client, chatId: thread.id })
    const seen: (string | undefined)[] = []
    const stop = effect(() => void seen.push(model.status.get()?.text))
    expect(t.core.subsOf("composeActions")).toEqual([{ kind: "composeActions", chatId: thread.id }])

    t.core.setCompose([typing(100, 2)])
    await t.flush()
    expect(model.status.peek()).toEqual({ kind: "typing", text: `${N("Ada Lovelace")} is typing` })
    expect(model.typing.peek()).toBe(true)

    t.core.setCompose([typing(100, 2), typing(100, 5)])
    await t.flush()
    expect(model.status.peek()?.text).toBe(`${N("Ada Lovelace")} and ${N("مریم میرزاخانی")} are typing`)

    t.core.setCompose([typing(100, 2), typing(100, 5), typing(100, 3), typing(100, 4)])
    await t.flush()
    expect(model.status.peek()?.text).toBe(`${N("Ada Lovelace")}, ${N("مریم میرزاخانی")} and 2 others are typing`)

    // Another chat's activity does not reach this chat's line.
    t.core.setCompose([typing(100, 2), typing(200, 2)])
    await t.flush()
    expect(model.status.peek()?.text).toBe(`${N("Ada Lovelace")} is typing`)

    // The core expired everyone (6 s without a refresh): the line goes.
    t.core.setCompose([])
    await t.flush()
    expect(model.status.peek()).toBeUndefined()
    expect(model.typing.peek()).toBe(false)
    expect(seen).toEqual([
      undefined,
      `${N("Ada Lovelace")} is typing`,
      `${N("Ada Lovelace")} and ${N("مریم میرزاخانی")} are typing`,
      `${N("Ada Lovelace")}, ${N("مریم میرزاخانی")} and 2 others are typing`,
      `${N("Ada Lovelace")} is typing`,
      undefined,
    ])
    stop()
    model.dispose()
    expect(t.core.subsOf("composeActions")).toEqual([])
  })

  it("says just 'typing' in a direct message", async () => {
    const t = await setup()
    const model = createChatTyping({ client: t.client, chatId: direct.id })
    const stop = effect(() => void model.status.get())
    t.core.setCompose([typing(200, 2)])
    await t.flush()
    expect(model.status.peek()).toEqual({ kind: "typing", text: "typing" })
    stop()
    model.dispose()
  })
})

describe("ComposeActivityIndex", () => {
  it("gives each sidebar row its own computed, so one chat's typing renders one row", async () => {
    const t = await setup()
    const index = createComposeActivityIndex({ client: t.client })
    const runs = { thread: 0, direct: 0 }
    const stops = [
      effect(() => {
        index.forChat(thread.id).get()
        runs.thread++
      }),
      effect(() => {
        index.forChat(direct.id).get()
        runs.direct++
      }),
    ]
    expect(t.core.subsOf("composeActions")).toEqual([{ kind: "composeActions" }])

    t.core.setCompose([typing(100, 2), typing(100, 3), typing(100, 4)])
    await t.flush()
    expect(index.forChat(thread.id).peek()).toEqual({ typing: true, status: { kind: "typing", text: `${N("Ada Lovelace")} and 2 others are typing` } })
    expect(index.forChat(direct.id).peek()).toEqual({ typing: false, status: undefined })
    expect(runs).toEqual({ thread: 2, direct: 1 })

    t.core.setCompose([typing(100, 2), typing(100, 3), typing(100, 4), typing(200, 2)])
    await t.flush()
    expect(index.forChat(direct.id).peek().typing).toBe(true)
    expect(runs).toEqual({ thread: 2, direct: 2 })
    for (const stop of stops) stop()
    index.dispose()
  })
})

describe("ComposeReporter (outgoing)", () => {
  const make = () => {
    const time = manualTime()
    const sent: (ComposeActionKind | null)[] = []
    const reporter = createComposeReporter({ chatId: cid(100), clock: time, send: (action) => sent.push(action) })
    return { time, sent, reporter }
  }

  it("sends typing at once, then at most every 3 s while typing continues", () => {
    const { time, sent, reporter } = make()
    reporter.noteTyping()
    expect(sent).toEqual(["typing"])
    time.advance(1_000)
    reporter.noteTyping()
    time.advance(1_999)
    reporter.noteTyping()
    expect(sent).toEqual(["typing"])
    time.advance(1)
    reporter.noteTyping()
    expect(sent).toEqual(["typing", "typing"])
    expect(COMPOSE_ACTION_RULE.refreshMs).toBe(3_000)
  })

  it("stops once when the composer empties or sends, and types again at once after", () => {
    const { time, sent, reporter } = make()
    reporter.stopTyping()
    expect(sent).toEqual([])
    reporter.noteTyping()
    time.advance(500)
    reporter.stopTyping()
    reporter.stopTyping()
    expect(sent).toEqual(["typing", null])
    time.advance(500)
    reporter.noteTyping()
    expect(sent).toEqual(["typing", null, "typing"])
  })

  it("follows a composer document: typing on edits, a stop when it empties, nothing for the restored draft", () => {
    const { time, sent, reporter } = make()
    const doc = signal({ text: "restored draft", revision: 4 })
    const stop = reporter.followComposer(doc)
    expect(sent).toEqual([])
    doc.set({ text: "restored draft!", revision: 5 })
    expect(sent).toEqual(["typing"])
    time.advance(3_000)
    doc.set({ text: "restored draft!!", revision: 6 })
    expect(sent).toEqual(["typing", "typing"])
    // Sent and cleared by the composer.
    doc.set({ text: "", revision: 7 })
    expect(sent).toEqual(["typing", "typing", null])
    stop()
  })

  it("counts uploads and recordings, shows the strongest, and keeps typing from clearing them", () => {
    const { sent, reporter } = make()
    reporter.noteTyping()
    const endPhoto = reporter.beginActivity("uploadingPhoto")
    const endDocument = reporter.beginActivity("uploadingDocument")
    expect(sent).toEqual(["typing", "uploadingPhoto"])
    reporter.noteTyping()
    reporter.stopTyping()
    expect(sent).toEqual(["typing", "uploadingPhoto"])
    const endRecording = reporter.beginActivity("recordingVoice")
    expect(sent).toEqual(["typing", "uploadingPhoto", "recordingVoice"])
    endRecording()
    endRecording()
    expect(sent).toEqual(["typing", "uploadingPhoto", "recordingVoice", "uploadingPhoto"])
    endPhoto()
    expect(sent.at(-1)).toBe("uploadingDocument")
    endDocument()
    expect(sent.at(-1)).toBe(null)
    expect(reporter.current()).toBe(null)
    // Typing is reported again at once after the activity ended.
    reporter.noteTyping()
    expect(sent.at(-1)).toBe("typing")
  })

  it("stops what it reported when the chat closes", () => {
    const { sent, reporter } = make()
    reporter.noteTyping()
    reporter.dispose()
    reporter.noteTyping()
    expect(sent).toEqual(["typing", null])
  })

  it("posts the composeAction intent through the store client by default", async () => {
    const t = await setup()
    const reporter = createComposeReporter({ chatId: thread.id, clock: t.time, client: t.client })
    reporter.noteTyping()
    reporter.stopTyping()
    expect(t.core.intentsOf("composeAction")).toEqual([
      { kind: "composeAction", chatId: thread.id, action: "typing" },
      { kind: "composeAction", chatId: thread.id, action: null },
    ])
  })
})
