import type { ChatRow, UserGroupRow, UserRow } from "@inline/core-protocol"
import { memberRowId, rowKey } from "@inline/core-protocol"
import { chatId as toChatId, spaceId as toSpaceId, userId as toUserId } from "@inline/ids"
import { effect } from "@inline/reactive"
import { afterEach, describe, expect, it } from "vitest"
import { createParticipantsModel, type ParticipantsModel } from "./participants-model"
import { testHarness, type TestHarness } from "./testing"

const uid = (n: number) => toUserId(String(n))
const cid = (n: number) => toChatId(String(n))
const space = toSpaceId("7")
const me = uid(1)

const users: UserRow[] = [
  { kind: "user", id: me, firstName: "Mo", lastName: "Rajabi", username: "mo" },
  { kind: "user", id: uid(2), firstName: "Ada", lastName: "Lovelace", username: "ada" },
  { kind: "user", id: uid(3), firstName: "Zoë", username: "zoe" },
  { kind: "user", id: uid(4), firstName: "Bot", bot: true, username: "helper_bot" },
  { kind: "user", id: uid(5), firstName: "مریم" },
]

const privateThread: ChatRow = { kind: "chat", id: cid(10), title: "Plans", spaceId: space }
const subthread: ChatRow = { kind: "chat", id: cid(11), title: "Sub", parentChatId: cid(10), spaceId: space }
const replyThread: ChatRow = { kind: "chat", id: cid(12), parentChatId: cid(11), parentMessageId: "99" as never, spaceId: space }
const publicThread: ChatRow = { kind: "chat", id: cid(20), title: "General", spaceId: space, isPublic: true }
const publicSub: ChatRow = { kind: "chat", id: cid(21), parentChatId: cid(20), spaceId: space }
const direct: ChatRow = { kind: "chat", id: cid(30), peerUserId: uid(2) }

const design: UserGroupRow = {
  kind: "userGroup",
  id: "500",
  spaceId: space,
  name: "Design",
  description: "Product design",
  memberCount: 2,
  userIds: [uid(3), uid(5)],
  currentUserIsMember: false,
}

let h: TestHarness | undefined
let model: ParticipantsModel | undefined
afterEach(() => {
  model?.dispose()
  h?.dispose()
  model = undefined
  h = undefined
})

const setup = async (options: { autoAnswer?: boolean } = {}) => {
  h = testHarness({ me, ...options })
  h.core.setUsers(users)
  for (const chat of [privateThread, subthread, replyThread, publicThread, publicSub, direct]) h.core.setChat(chat)
  h.core.setGroups([design])
  h.core.setParticipants(cid(10), [me, uid(2), uid(5)], { groupIds: ["500"] })
  h.core.setParticipants(cid(11), [uid(4)])
  h.core.setSpaceMembers(space, [
    { userId: uid(2), role: "owner", date: 1 },
    { userId: me, role: "member", date: 5 },
    { userId: uid(3), role: "member", canAccessPublicChats: false, date: 3 },
    { userId: uid(4), role: "admin", date: 2 },
  ])
  return h
}

const observe = (m: ParticipantsModel) =>
  effect(() => {
    m.ids.get()
    m.status.get()
    m.access.get()
  })

describe("participants: the Mac's fallbacks", () => {
  it("lists a private thread's own participants, groups first, then people by name", async () => {
    const t = await setup()
    model = createParticipantsModel({ client: t.client, chatId: cid(10), viewerId: me, clock: t.time })
    const stop = observe(model)
    await t.flush()
    expect(model.source.peek()).toEqual({ kind: "chat", chatId: cid(10), inherited: false, spaceId: space })
    expect(model.ids.peek()).toEqual([
      rowKey("userGroup", "500"),
      rowKey("member", memberRowId({ chatId: cid(10) }, uid(2))),
      rowKey("member", memberRowId({ chatId: cid(10) }, me)),
      rowKey("member", memberRowId({ chatId: cid(10) }, uid(5))),
    ])
    expect(model.member(rowKey("userGroup", "500")).peek()).toMatchObject({ kind: "group", name: "Design", subtitle: "Product design - 2 people" })
    expect(model.member(rowKey("member", memberRowId({ chatId: cid(10) }, me))).peek()).toMatchObject({
      kind: "user",
      name: "Mo Rajabi",
      username: "mo",
      isViewer: true,
    })
    expect(model.status.peek()).toBe("ready")
    expect(model.complete.peek()).toBe(true)
    expect(model.counts.peek()).toEqual({ people: 3, groups: 1 })
    // Group members have access through the group.
    expect([...model.access.peek().userIds].sort()).toEqual([me, uid(2), uid(3), uid(5)].sort())
    expect([...model.access.peek().groupIds]).toEqual(["500"])
    stop()
  })

  it("gives a subthread and a reply thread under it the root chat's list, with their own grants counted for access", async () => {
    const t = await setup()
    model = createParticipantsModel({ client: t.client, chatId: cid(12), viewerId: me, clock: t.time })
    const stop = observe(model)
    await t.flush()
    expect(model.source.peek()).toEqual({ kind: "chat", chatId: cid(10), inherited: true, spaceId: space })
    expect(model.root.peek()?.id).toBe(cid(10))
    expect(model.ids.peek()).toHaveLength(4)
    expect(t.core.subsOf("chatParticipants").map((query) => query.chatId).sort()).toEqual([cid(10), cid(12)])
    stop()
    model.dispose()

    model = createParticipantsModel({ client: t.client, chatId: cid(11), viewerId: me, clock: t.time })
    const stop2 = observe(model)
    await t.flush()
    // The subthread's own grant (the bot) is access, not part of the shown list.
    expect(model.ids.peek()).toHaveLength(4)
    expect(model.access.peek().userIds.has(uid(4))).toBe(true)
    stop2()
  })

  it("gives a public thread (and a subthread of one) the space's members, the viewer first, then by join date", async () => {
    const t = await setup()
    model = createParticipantsModel({ client: t.client, chatId: cid(21), viewerId: me, clock: t.time })
    const stop = observe(model)
    await t.flush()
    expect(model.source.peek()).toEqual({ kind: "space", chatId: cid(20), spaceId: space, inherited: true })
    const items = model.ids.peek().map((key) => model!.member(key).peek())
    expect(items.map((item) => item?.kind === "user" && item.userId)).toEqual([me, uid(2), uid(4), uid(3)])
    expect(items.map((item) => item?.kind === "user" && [item.role, item.restricted])).toEqual([
      [undefined, false],
      ["owner", false],
      ["admin", false],
      [undefined, true],
    ])
    // A restricted member cannot read public chats.
    expect(model.access.peek().userIds.has(uid(3))).toBe(false)
    expect(t.core.subsOf("spaceMembers")).toEqual([{ kind: "spaceMembers", spaceId: space }])
    stop()
  })

  it("lists a direct message's peer", async () => {
    const t = await setup()
    model = createParticipantsModel({ client: t.client, chatId: cid(30), viewerId: me, clock: t.time })
    const stop = observe(model)
    await t.flush()
    expect(model.source.peek()).toEqual({ kind: "direct", chatId: cid(30), peerUserId: uid(2), inherited: false })
    expect(model.ids.peek()).toEqual([rowKey("user", uid(2))])
    expect(model.member(rowKey("user", uid(2))).peek()).toMatchObject({ name: "Ada Lovelace" })
    expect(model.complete.peek()).toBe(true)
    expect(model.status.peek()).toBe("ready")
    stop()
  })

  it("ends the chain at a parent that never arrives, after the wait", async () => {
    const t = await setup()
    t.core.setChat({ kind: "chat", id: cid(40), parentChatId: cid(999), spaceId: space })
    t.core.setParticipants(cid(40), [uid(2)])
    model = createParticipantsModel({ client: t.client, chatId: cid(40), viewerId: me, clock: t.time, missingChatWaitMs: 1_000 })
    const stop = observe(model)
    await t.flush()
    expect(model.source.peek()).toEqual({ kind: "resolving" })
    expect(model.status.peek()).toBe("pending")
    expect(model.showEmpty.peek()).toBe(false)
    t.time.advance(1_000)
    await t.flush()
    expect(model.source.peek()).toEqual({ kind: "chat", chatId: cid(40), inherited: false, spaceId: space })
    expect(model.ids.peek()).toHaveLength(1)
    stop()
  })
})

describe("participants: loading and completion", () => {
  it("is pending (not empty) before the core answers, shows the device's list while loading, then completes", async () => {
    const t = await setup({ autoAnswer: false })
    t.core.setParticipants(cid(10), [uid(2)], { complete: false, loading: true })
    model = createParticipantsModel({ client: t.client, chatId: cid(10), viewerId: me, clock: t.time })
    const statuses: string[] = []
    const stop = effect(() => {
      statuses.push(`${model!.status.get()}:${model!.ids.get().length}:${model!.showEmpty.get()}`)
    })
    t.core.answer((query) => query.kind === "chat")
    await t.flush()
    expect(model.status.peek()).toBe("pending")
    t.core.answer()
    await t.flush()
    expect(model.status.peek()).toBe("loading")
    expect(model.complete.peek()).toBe(false)
    t.core.setParticipants(cid(10), [me, uid(2), uid(5)], { complete: true, loading: false })
    await t.flush()
    expect(model.status.peek()).toBe("ready")
    expect(model.complete.peek()).toBe(true)
    // The Design group's grant is listed too.
    expect(statuses).toEqual(["pending:0:false", "loading:2:false", "ready:4:false"])
    stop()
  })

  it("shows the empty state only for an answered empty list", async () => {
    const t = await setup()
    t.core.setChat({ kind: "chat", id: cid(50), title: "Empty" })
    t.core.setParticipants(cid(50), [])
    model = createParticipantsModel({ client: t.client, chatId: cid(50), viewerId: me, clock: t.time })
    const stop = observe(model)
    expect(model.showEmpty.peek()).toBe(false)
    await t.flush()
    expect(model.showEmpty.peek()).toBe(true)
    stop()
  })

  it("holds the previous list while a new source answers, then releases its subscription", async () => {
    const t = await setup()
    t.core.setChat({ kind: "chat", id: cid(60), title: "Going public", spaceId: space })
    t.core.setParticipants(cid(60), [uid(2)])
    model = createParticipantsModel({ client: t.client, chatId: cid(60), viewerId: me, clock: t.time })
    const stop = observe(model)
    await t.flush()
    const before = model.ids.peek()
    expect(before).toHaveLength(1)
    t.core.autoAnswer = false
    t.core.setChat({ kind: "chat", id: cid(60), title: "Going public", spaceId: space, isPublic: true })
    await t.flush()
    expect(model.source.peek().kind).toBe("space")
    expect(model.ids.peek()).toBe(before)
    t.core.answer()
    await t.flush()
    expect(model.ids.peek()).toHaveLength(4)
    expect(t.core.subsOf("chatParticipants").map((q) => q.chatId)).toEqual([cid(60)])
    stop()
  })
})

describe("participants: one member changing", () => {
  it("re-runs only that member's computed", async () => {
    const t = await setup()
    const people = Array.from({ length: 300 }, (_, i) => ({ kind: "user" as const, id: uid(1000 + i), firstName: `Person ${i}` }))
    t.core.setUsers(people)
    t.core.setChat({ kind: "chat", id: cid(70), title: "Big", spaceId: space })
    t.core.setParticipants(cid(70), people.map((p) => p.id))
    model = createParticipantsModel({ client: t.client, chatId: cid(70), viewerId: me, clock: t.time })
    const stop = observe(model)
    await t.flush()
    const keys = model.ids.peek()
    expect(keys).toHaveLength(300)
    const runs = new Map<string, number>()
    const stops = keys.map((key) =>
      effect(() => {
        model!.member(key).get()
        runs.set(key, (runs.get(key) ?? 0) + 1)
      }),
    )
    const listRuns = { count: 0 }
    const stopList = effect(() => {
      model!.ids.get()
      listRuns.count++
    })
    // Renamed without moving in the order (the core sorts by name).
    t.core.setUser({ kind: "user", id: uid(1000), firstName: "Person 0", lastName: "Renamed" })
    await t.flush()
    const changed = [...runs.entries()].filter(([, count]) => count > 1).map(([key]) => key)
    expect(changed).toEqual([rowKey("member", memberRowId({ chatId: cid(70) }, uid(1000)))])
    expect(listRuns.count).toBe(1)
    for (const s of stops) s()
    stopList()
    stop()
  })
})
