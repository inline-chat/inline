import type { ChatRow, UserRow } from "@inline/core-protocol"
import { chatId as toChatId, spaceId as toSpaceId, userId as toUserId } from "@inline/ids"
import { effect, signal } from "@inline/reactive"
import { IntentTracker } from "@inline/view/features"
import { afterEach, describe, expect, it } from "vitest"
import { createChatInfoModel, type ChatInfoModel } from "./chat-info-model"
import { testHarness, type TestHarness } from "./testing"

const uid = (n: number) => toUserId(String(n))
const me = uid(1)
const space = toSpaceId("7")
const users: UserRow[] = [
  { kind: "user", id: me, firstName: "Mo" },
  { kind: "user", id: uid(2), firstName: "Ada", username: "ada" },
  { kind: "user", id: uid(3), firstName: "Alan", username: "alan" },
  { kind: "user", id: uid(4), firstName: "Grace", username: "grace" },
  { kind: "user", id: uid(5), firstName: "Linus" },
]
const privateThread = (extra: Partial<ChatRow> = {}): ChatRow => ({ kind: "chat", id: toChatId("10"), title: "Plan", spaceId: space, ...extra })

let h: TestHarness | undefined
let model: ChatInfoModel | undefined
let tracker: IntentTracker | undefined
let stops: (() => void)[] = []
afterEach(() => {
  for (const stop of stops) stop()
  stops = []
  model?.dispose()
  tracker?.dispose()
  h?.dispose()
  model = undefined
  tracker = undefined
  h = undefined
})

type Notice = { kind: string; title?: string; text?: string }

const setup = async (options: { chat?: ChatRow; role?: "owner" | "admin" | "member" } = {}) => {
  h = testHarness({ me })
  const chat = options.chat ?? privateThread()
  h.core.setUsers(users)
  h.core.setChat(chat)
  h.core.setParticipants(chat.id, [me, uid(2), uid(3)])
  h.core.setSpaceMembers(space, [
    { userId: me, role: options.role ?? "member" },
    { userId: uid(2) },
    { userId: uid(3) },
    { userId: uid(4) },
    { userId: uid(5) },
  ])
  h.client.subscribe({ kind: "chat", chatId: chat.id })
  await h.flush()
  tracker = new IntentTracker({ core: h.core.endpoint, store: h.client.store })
  const notices: Notice[] = []
  model = createChatInfoModel({
    client: h.client,
    chatId: chat.id,
    viewerId: me,
    dialog: signal(undefined),
    intents: tracker,
    onOpenProfile: () => {},
    clock: h.time,
    onNotice: (notice) => notices.push(notice as Notice),
  })
  // Observe like the view does.
  stops.push(
    effect(() => {
      model!.members.ids.get()
      model!.members.canAdd.get()
      model!.members.canManage.get()
      model!.addPeople.matches.get()
    }),
  )
  await h.flush()
  return { h, model, notices }
}

const names = (m: ChatInfoModel) =>
  m.members.ids.peek().map((key) => {
    const item = m.participants.member(key).peek()
    return item?.name ?? key
  })

const keyOf = (m: ChatInfoModel, name: string) => m.members.ids.peek().find((key) => m.participants.member(key).peek()?.name === name)!

describe("chat info: who may add and remove (ChatParticipantPolicy)", () => {
  it("anyone in a private thread may add; only the creator or a space owner or admin may remove, never themselves", async () => {
    const member = await setup()
    expect(member.model.members.canAdd.peek()).toBe(true)
    expect(member.model.members.canManage.peek()).toBe(false)
    expect(member.model.members.canRemove(keyOf(member.model, "Ada"))).toBe(false)
    member.model.dispose()
    model = undefined
    h?.dispose()

    const admin = await setup({ role: "admin" })
    expect(admin.model.members.canManage.peek()).toBe(true)
    expect(admin.model.members.canRemove(keyOf(admin.model, "Ada"))).toBe(true)
    expect(admin.model.members.canRemove(keyOf(admin.model, "Mo"))).toBe(false)
    admin.model.dispose()
    model = undefined
    h?.dispose()

    const creator = await setup({ chat: privateThread({ createdBy: me }) })
    expect(creator.model.members.canManage.peek()).toBe(true)
  })

  it("a public thread or a direct message offers neither", async () => {
    const pub = await setup({ chat: privateThread({ isPublic: true, createdBy: me }) })
    expect(pub.model.members.canAdd.peek()).toBe(false)
    expect(pub.model.members.canManage.peek()).toBe(false)
  })
})

describe("chat info: adding people", () => {
  it("offers the space's members who are not in the chat, filters as typed, and adds the picks with Enter", async () => {
    const { h, model, notices } = await setup()
    const picker = model.addPeople
    expect(h.core.subsOf("spaceMembers")).toHaveLength(1)
    picker.open()
    await h.flush()
    expect(picker.matches.peek().map((c) => c.name)).toEqual(["Grace", "Linus"])
    picker.setQuery("gr")
    expect(picker.matches.peek().map((c) => c.name)).toEqual(["Grace"])
    expect(picker.handleKey("Enter")).toBe(true)
    expect(picker.pickedPeople.peek().map((c) => c.name)).toEqual(["Grace"])
    expect(picker.query.peek()).toBe("")
    picker.setQuery("li")
    picker.handleKey("Enter")
    // Backspace in the empty field drops the last pick; pick it again.
    expect(picker.handleKey("Backspace")).toBe(true)
    picker.setQuery("li")
    picker.handleKey("Enter")
    h.core.intentMode = "hold"
    expect(picker.handleKey("Enter")).toBe(true)
    expect(picker.isOpen.peek()).toBe(false)
    expect(h.core.intentsOf("addChatParticipants")).toEqual([{ kind: "addChatParticipants", chatId: "10", userIds: [uid(4), uid(5)] }])
    // In the list in the same task, before the core answers.
    expect(names(model)).toEqual(["Ada", "Alan", "Mo", "Grace", "Linus"])
    await h.flush()
    expect(names(model)).toContain("Grace")
    h.core.settleHeld("confirmed")
    await h.flush()
    expect(names(model).filter((name) => name === "Grace")).toHaveLength(1)
    expect(model.members.state.peek()).toEqual({ kind: "done", text: "Added Grace and Linus." })
    expect(notices.at(-1)).toMatchObject({ kind: "done" })
    // They are in now: the picker no longer offers them.
    picker.open()
    expect(picker.matches.peek()).toEqual([])
  })

  it("takes the added people back out when the core refuses, and says why", async () => {
    const { h, model, notices } = await setup()
    h.core.intentMode = "reject"
    model.members.add([uid(4)])
    expect(names(model)).toContain("Grace")
    await h.flush()
    expect(names(model)).not.toContain("Grace")
    expect(model.members.state.peek().kind).toBe("failed")
    expect(notices.at(-1)).toMatchObject({ kind: "refused" })
  })
})

describe("chat info: removing", () => {
  it("asks first, hides the row at once, and keeps it gone when confirmed", async () => {
    const { h, model, notices } = await setup({ role: "owner" })
    const ada = keyOf(model, "Ada")
    model.members.requestRemove(ada)
    expect(model.members.question.peek()).toEqual({ key: ada, title: "Remove participant?", text: "Remove Ada from this chat?", confirm: "Remove" })
    model.members.cancelRemove()
    expect(h.core.intentsOf("removeChatParticipant")).toEqual([])
    h.core.intentMode = "hold"
    model.members.requestRemove(ada)
    model.members.confirmRemove()
    expect(h.core.intentsOf("removeChatParticipant")).toEqual([{ kind: "removeChatParticipant", chatId: "10", userId: uid(2) }])
    expect(names(model)).toEqual(["Alan", "Mo"])
    await h.flush()
    h.core.settleHeld("confirmed")
    await h.flush()
    expect(names(model)).toEqual(["Alan", "Mo"])
    expect(notices.at(-1)).toMatchObject({ kind: "done", text: "Removed Ada." })
  })

  it("puts the row back when the server refuses and the refetched list still has them", async () => {
    const { h, model, notices } = await setup({ role: "owner" })
    h.core.intentMode = "reject"
    model.members.requestRemove(keyOf(model, "Ada"))
    model.members.confirmRemove()
    expect(names(model)).toEqual(["Alan", "Mo"])
    await h.flush()
    // The core refetches the roster after a refusal.
    h.core.setParticipants("10" as never, [me, uid(2), uid(3)], { loading: true })
    await h.flush()
    h.core.setParticipants("10" as never, [me, uid(2), uid(3)], { loading: false })
    await h.flush()
    expect(names(model)).toEqual(["Ada", "Alan", "Mo"])
    expect(model.members.state.peek().kind).toBe("failed")
    expect(notices.at(-1)).toMatchObject({ kind: "refused" })
  })

  it("a refused remove of someone already gone (a retry after a lost acknowledgement) counts as done", async () => {
    const { h, model, notices } = await setup({ role: "owner" })
    h.core.intentMode = "reject"
    model.members.requestRemove(keyOf(model, "Ada"))
    model.members.confirmRemove()
    await h.flush()
    // The first attempt reached the server: the refetched list has no Ada.
    h.core.setParticipants("10" as never, [me, uid(3)], { loading: true })
    await h.flush()
    h.core.setParticipants("10" as never, [me, uid(3)])
    await h.flush()
    expect(names(model)).toEqual(["Alan", "Mo"])
    expect(model.members.state.peek()).toEqual({ kind: "done", text: "Removed." })
    expect(notices.some((notice) => notice.kind === "refused")).toBe(false)
  })

  it("gives up waiting for the refetch after a while and says it was refused", async () => {
    const { h, model } = await setup({ role: "owner" })
    h.core.intentMode = "reject"
    model.members.requestRemove(keyOf(model, "Ada"))
    model.members.confirmRemove()
    await h.flush()
    h.time.advance(8_000)
    await h.flush()
    expect(names(model)).toEqual(["Ada", "Alan", "Mo"])
    expect(model.members.state.peek().kind).toBe("failed")
  })

  it("offers Remove in the row's context menu only where it may", async () => {
    const { model } = await setup({ role: "admin" })
    const ada = keyOf(model, "Ada")
    expect(model.participantActions(ada)).toMatchObject([{ type: "item", id: "remove", label: "Remove Participant", destructive: true }])
    expect(model.participantActions(keyOf(model, "Mo"))).toEqual([])
    const remove = model.participantActions(ada)[0]
    if (remove?.type === "item") remove.onSelect?.()
    expect(model.members.question.peek()?.title).toBe("Remove participant?")
  })
})
