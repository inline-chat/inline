import type { ChatRow, MemberRow, UserGroupRow, UserRow } from "@inline/core-protocol"
import { chatId as toChatId, spaceId as toSpaceId, userId as toUserId, type UserID } from "@inline/ids"
import { computed, effect, signal } from "@inline/reactive"
import { afterEach, describe, expect, it } from "vitest"
import { createParticipantsModel, type ParticipantsModel } from "../chat-info/participants-model"
import { testHarness, type TestHarness } from "../chat-info/testing"
import {
  canRemoveParticipants,
  createMentionSuggestions,
  mentionAddContext,
  mentionAddDecision,
  mentionedUserIds,
  policyMessageCount,
  recentSenders,
  type DirectPeer,
  type MentionSuggestions,
} from "./index"

const uid = (n: number) => toUserId(String(n))
const cid = (n: number) => toChatId(String(n))
const space = toSpaceId("7")
const me = uid(1)

const users: UserRow[] = [
  { kind: "user", id: me, firstName: "Mo", lastName: "Rajabi", username: "mo" },
  { kind: "user", id: uid(2), firstName: "Ada", lastName: "Lovelace", username: "ada" },
  { kind: "user", id: uid(3), firstName: "Zoë", username: "zoe" },
  { kind: "user", id: uid(4), firstName: "Helper", bot: true, username: "helper_bot" },
  { kind: "user", id: uid(5), firstName: "مریم", lastName: "میرزاخانی" },
  { kind: "user", id: uid(6), firstName: "Émile", lastName: "Borel", username: "emile" },
  { kind: "user", id: uid(8), firstName: "Yuki", lastName: "由紀" },
  { kind: "user", id: uid(9), firstName: "Grace", lastName: "Hopper", username: "grace" },
]

const design: UserGroupRow = {
  kind: "userGroup",
  id: "500",
  spaceId: space,
  name: "Design",
  description: "Product design",
  memberCount: 1,
  userIds: [uid(3)],
  currentUserIsMember: false,
}
const engineering: UserGroupRow = { ...design, id: "501", name: "Engineering", description: "Builds things", memberCount: 4, userIds: [uid(6)] }

const thread: ChatRow = { kind: "chat", id: cid(10), title: "Plans", spaceId: space }

let h: TestHarness | undefined
let participants: ParticipantsModel | undefined
let mentions: MentionSuggestions | undefined
afterEach(() => {
  mentions?.dispose()
  participants?.dispose()
  h?.dispose()
  mentions = undefined
  participants = undefined
  h = undefined
})

const setup = async (options: { recent?: UserID[]; direct?: DirectPeer[]; membersComplete?: boolean } = {}) => {
  h = testHarness({ me })
  h.core.setUsers(users)
  h.core.setChat(thread)
  h.core.setGroups([design, engineering])
  h.core.setParticipants(cid(10), [me, uid(2), uid(5)], { groupIds: ["500"] })
  h.core.setSpaceMembers(
    space,
    options.membersComplete === false ? [{ userId: me }] : [me, 2, 3, 4, 5, 6, 8].map((n) => ({ userId: typeof n === "number" ? uid(n) : n })),
    { complete: options.membersComplete !== false, loading: options.membersComplete === false },
  )
  // Direct-chat peers' user rows come with the sidebar in the app.
  h.client.subscribe({ kind: "user", userId: uid(9) })
  participants = createParticipantsModel({ client: h.client, chatId: cid(10), viewerId: me, clock: h.time })
  mentions = createMentionSuggestions({
    client: h.client,
    viewerId: me,
    participants,
    recentSenders: signal(options.recent ?? []),
    directPeers: signal(options.direct ?? []),
  })
  const stop = effect(() => void mentions!.candidates.get())
  await h.flush()
  return { t: h, m: mentions, stop }
}

const titles = (rows: readonly { title: string }[]) => rows.map((row) => row.title)
const at = (query: string) => ({ kind: "mention" as const, query, range: { from: 0, to: 1 + query.length } })

describe("mention suggestions: order (Mac MentionCompletionCandidate.precedes)", () => {
  it("puts access first, then recent speakers, pinned and recent direct chats, groups, participants, members; never the viewer", async () => {
    const { m, stop } = await setup({
      recent: [uid(5), me, uid(4)],
      direct: [
        { userId: uid(9), lastMessageDate: 100 },
        { userId: uid(2), lastMessageDate: 50, pinned: true },
      ],
    })
    expect(titles(m.suggest(at("")))).toEqual([
      "مریم میرزاخانی", // access, spoke last
      "Ada Lovelace", // access, pinned direct chat
      "Design", // a group with access, before people at the same rank
      "Zoë", // access through the Design group
      "Helper", // a member who spoke recently
      "Engineering", // a group without access, before members
      "Émile Borel",
      "Yuki 由紀",
    ])
    // Grace is known only from a direct chat: offered when searched.
    expect(titles(m.suggest(at("gr")))).toEqual(["Grace Hopper"])
    expect(m.suggest({ kind: "emoji", query: "gr", range: { from: 0, to: 3 } })).toEqual([])
    stop()
  })

  it("buckets matches the Mac way: exact username, exact name, whole words, prefix, then descriptions", async () => {
    const { m, stop } = await setup()
    expect(titles(m.rows("zoe"))).toEqual(["Zoë"])
    expect(titles(m.rows("helper"))).toEqual(["Helper"])
    // "design" is a whole word of the group's name (exact) and of its description (detail).
    expect(titles(m.rows("design"))).toEqual(["Design"])
    // "build" is only in Engineering's description: it ranks with details.
    expect(titles(m.rows("build"))).toEqual(["Engineering"])
    // "e": word prefixes first, then substrings, each bucket in the base order (access first, groups before people).
    expect(titles(m.rows("e"))).toEqual(["Engineering", "Émile Borel", "Design", "Ada Lovelace", "Zoë", "Helper"])
    // "ada l": whole words of a name beat a username prefix.
    expect(titles(m.rows("ada l"))).toEqual(["Ada Lovelace"])
    // Punctuation alone matches nothing.
    expect(m.rows(".")).toEqual([])
    stop()
  })

  it("folds scripts and accents with the shared matcher", async () => {
    const { m, stop } = await setup()
    // Arabic yeh typed for the Persian one.
    expect(titles(m.rows("مريم"))).toEqual(["مریم میرزاخانی"])
    expect(titles(m.rows("emile"))).toEqual(["Émile Borel"])
    expect(titles(m.rows("由紀"))).toEqual(["Yuki 由紀"])
    stop()
  })
})

describe("mention suggestions: what a row carries", () => {
  it("gives the composer a mention atom and label, and the list what it draws", async () => {
    const { m, stop } = await setup()
    const [ada] = m.rows("ada")
    expect(ada).toMatchObject({
      id: `user:${uid(2)}`,
      title: "Ada Lovelace",
      subtitle: "@ada",
      avatar: { name: "Ada Lovelace", seed: "Ada Lovelace" },
      item: { kind: "mention", atom: { type: "mention", userId: uid(2) }, label: "@Ada" },
      mention: { kind: "user", userId: uid(2), bot: false, source: "participant", hasAccess: true },
    })
    expect(m.rows("helper")[0]?.item).toEqual({ kind: "mention", atom: { type: "mention", userId: uid(4) }, label: "@Helper" })
    expect(m.rows("design")[0]).toMatchObject({
      subtitle: "Product design - 1 person",
      item: { kind: "mention", atom: { type: "groupMention", groupId: "500" }, label: "@Design" },
      mention: { kind: "group", groupId: "500", hasAccess: true },
    })
    // Rows keep their identity between calls, so the composer's list does not re-render.
    expect(m.rows("")[0]).toBe(m.rows("")[0])
    stop()
  })
})

describe("mention suggestions: updating", () => {
  it("is synchronous for what is on the device and grows when the member list completes", async () => {
    const { t, m, stop } = await setup({ membersComplete: false })
    const seen: number[] = []
    const watch = effect(() => void seen.push(m.suggest(at("")).length))
    // Participants and both groups are on the device; Zoë (access through Design) has no user row yet.
    expect(titles(m.rows(""))).toEqual(["Design", "Ada Lovelace", "مریم میرزاخانی", "Engineering"])
    t.core.setSpaceMembers(space, [me, 2, 3, 4, 5, 6, 8].map((n) => ({ userId: typeof n === "number" ? uid(n) : n })), { complete: true })
    await t.flush()
    expect(titles(m.rows(""))).toEqual(["Design", "Ada Lovelace", "Zoë", "مریم میرزاخانی", "Engineering", "Émile Borel", "Helper", "Yuki 由紀"])
    expect(seen).toEqual([4, 8])
    watch()
    stop()
  })

  it("reads recent speakers from a chat window, newest first, each once", () => {
    const keys = signal(["m:1", "m:2", "m:3", "m:4"] as never[])
    const rows: Record<string, { fromId: UserID }> = {
      "m:1": { fromId: uid(2) },
      "m:2": { fromId: uid(5) },
      "m:3": { fromId: uid(2) },
      "m:4": { fromId: me },
    }
    const recent = recentSenders({ rowKeys: keys, row: (key) => computed(() => rows[key]) })
    expect(recent.peek()).toEqual([me, uid(2), uid(5)])
  })
})

describe("mention add policy (rule 14)", () => {
  const base = {
    isThread: true,
    isPublic: false,
    isReplyThread: false,
    viewerId: me,
    messageCount: 3,
    participantIds: new Set([me, uid(2)]),
  }

  it.each([
    ["a private thread with few messages adds", base, { kind: "autoAdd", userIds: [uid(3), uid(12)] }],
    ["a private thread with 10 messages asks", { ...base, messageCount: 10 }, { kind: "prompt", userIds: [uid(3), uid(12)] }],
    ["a reply thread adds whatever its length", { ...base, isReplyThread: true, messageCount: 500 }, { kind: "autoAdd", userIds: [uid(3), uid(12)] }],
    ["a sender who cannot remove is asked", { ...base, canRemoveParticipants: false }, { kind: "prompt", userIds: [uid(3), uid(12)] }],
    ["a public thread does nothing", { ...base, isPublic: true }, { kind: "none" }],
    ["a direct message does nothing", { ...base, isThread: false }, { kind: "none" }],
    ["no viewer does nothing", { ...base, viewerId: undefined }, { kind: "none" }],
    ["people already in or being added are left out", { ...base, pendingUserIds: new Set([uid(3), uid(12)]) }, { kind: "none" }],
  ] as const)("%s", (_, context, expected) => {
    expect(mentionAddDecision([uid(12), uid(3), uid(2), me, uid(3), "0" as UserID], context)).toEqual(expected)
  })

  it("counts messages from the window, judging a window with older messages as long", () => {
    expect(policyMessageCount({ loaded: 4, hasOlder: false })).toBe(4)
    expect(policyMessageCount({ loaded: 4, hasOlder: true })).toBe(10)
    expect(mentionAddDecision([uid(3)], { ...base, messageCount: policyMessageCount({ loaded: 4, hasOlder: true }) }).kind).toBe("prompt")
  })

  it("lets the creator and the space's owners and admins remove", () => {
    const chat: ChatRow = { kind: "chat", id: cid(10), spaceId: space, createdBy: uid(2) }
    const membership = (role: MemberRow["role"]): MemberRow => ({ kind: "member", id: "m", userId: me, spaceId: space, ...(role ? { role } : {}) })
    expect(canRemoveParticipants({ chat, viewerId: uid(2) })).toBe(true)
    expect(canRemoveParticipants({ chat, viewerId: me, membership: membership("admin") })).toBe(true)
    expect(canRemoveParticipants({ chat, viewerId: me, membership: membership("owner") })).toBe(true)
    expect(canRemoveParticipants({ chat, viewerId: me, membership: membership("member") })).toBe(false)
    expect(canRemoveParticipants({ chat: { ...chat, peerUserId: uid(2) }, viewerId: uid(2) })).toBe(false)
  })

  it("builds the context from a chat row and reads mentions from entities", () => {
    const reply: ChatRow = { kind: "chat", id: cid(11), parentChatId: cid(10), parentMessageId: "5" as never, spaceId: space, createdBy: me }
    const context = mentionAddContext({ chat: reply, viewerId: me, messageCount: 40, participantIds: new Set([me]) })
    expect(context).toMatchObject({ isThread: true, isPublic: false, isReplyThread: true, canRemoveParticipants: true })
    const ids = mentionedUserIds([
      { type: "mention", offset: 0, length: 4, userId: uid(3) },
      { type: "groupMention", offset: 5, length: 7, groupId: "500" },
      { type: "bold", offset: 0, length: 2 },
    ])
    expect(mentionAddDecision(ids, context)).toEqual({ kind: "autoAdd", userIds: [uid(3)] })
  })
})
