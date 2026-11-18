import { Method, RpcError_Code, type User as ProtocolUser } from "@inline-chat/protocol/core"
import { rowKey, type MemberRow, type RosterResource, type SpaceRow } from "@inline/core-protocol"
import { chatId as makeChatId, spaceId as makeSpaceId } from "@inline/ids"
import { afterEach, describe, expect, it } from "vitest"
import { DbObjectKind, type Space } from "../../database/models"
import { encodeUser } from "../../testing/server-model"
import { TestContext } from "./fixtures"
import { ModelHost, self } from "./model-host"

/**
 * Member lists against the real host: fetched on first subscribe when the
 * replica's list is not complete, ordered as the Mac shows them, kept live
 * from the replica, one member changing one row.
 */

const SPACE = 50n
const space = makeSpaceId(SPACE)
const chat = makeChatId(10)

const running: ModelHost[] = []
afterEach(async () => {
  for (const host of running.splice(0)) await host.dispose()
})

const spaceRow = (id: bigint, name: string): Space => ({
  kind: DbObjectKind.Space,
  id: makeSpaceId(id),
  name,
  creator: id === SPACE,
  date: 1,
})

const boot = async () => {
  const mh = new ModelHost()
  running.push(mh)
  mh.model.addUser(2n, "Zed")
  mh.model.addUser(3n, "ann")
  mh.model.addUser(4n, "Bea")
  mh.model.addSpace(SPACE, "Work")
  mh.model.addSpaceMember(SPACE, 3n)
  await mh.time.advance(10_000)
  mh.model.addSpaceMember(SPACE, 2n)
  mh.model.addChat({ id: 10n, title: "Design", participants: [2n, 3n] })
  const users = (ids: bigint[]): ProtocolUser[] =>
    ids.map((id) => encodeUser(mh.model.users.get(id)!))
  mh.respond = (_method, input) => {
    if (input.oneofKind === "getSpaceMembers") {
      const members = Array.from(mh.model.spaceMembersThrough(SPACE, mh.model.bucketSeq(`space:${SPACE}`)))
      return {
        result: {
          oneofKind: "getSpaceMembers",
          getSpaceMembers: {
            members: [
              { id: 1n, spaceId: SPACE, userId: 1n, date: 1n, role: 1, canAccessPublicChats: true },
              ...members.map(([userId, memberId]) => ({
                id: memberId,
                spaceId: SPACE,
                userId,
                date: BigInt(100 + Number(memberId)),
                canAccessPublicChats: true,
              })),
            ],
            users: users([1n, ...members.map(([userId]) => userId)]),
            seq: mh.model.bucketSeq(`space:${SPACE}`),
          },
        } as never,
      }
    }
    if (input.oneofKind === "getChatParticipants") {
      return {
        result: {
          oneofKind: "getChatParticipants",
          getChatParticipants: {
            participants: [
              { userId: 2n, date: 5n },
              { userId: 3n, date: 6n },
            ],
            users: users([2n, 3n]),
            groupParticipants: [{ groupId: 900n, date: 7n }],
            groups: [
              {
                id: 900n,
                spaceId: SPACE,
                name: "Designers",
                memberCount: 2,
                userIds: [2n, 3n],
                currentUserIsMember: false,
                date: 7n,
              },
            ],
          },
        } as never,
      }
    }
    return undefined
  }
  await mh.seedDisk([spaceRow(SPACE, "Work"), spaceRow(51n, "Alpha")])
  await mh.start()
  return mh
}

const fetches = (mh: ModelHost, method: Method) => mh.extraRpcs.filter((rpc) => rpc.method === method).length
const roster = (ui: TestContext, sub: number) => ui.state.resources.get(sub) as RosterResource | undefined

describe("spaceMembers", () => {
  it("fetches on first subscribe, orders the account first then by join date, and carries the users", async () => {
    const mh = await boot()
    mh.ui.subscribeTo(2, { kind: "spaceMembers", spaceId: space })
    await mh.until(() => roster(mh.ui, 2)?.complete === true && roster(mh.ui, 2)?.loading === false, "roster")
    expect(fetches(mh, Method.GET_SPACE_MEMBERS)).toBe(1)
    const rows = mh.ui.rows(2) as MemberRow[]
    expect(rows.map((row) => row.userId)).toEqual(["1", "3", "2"])
    expect(rows[0]).toMatchObject({ kind: "member", id: `space:${space}:1`, role: "admin", spaceId: space })
    for (const row of rows) expect(mh.ui.state.rows.get(rowKey("user", row.userId))).toBeDefined()

    // A second context does not fetch again: the list is complete and live.
    const other = new TestContext(mh.host.openContext())
    other.subscribeTo(1, { kind: "spaceMembers", spaceId: space })
    await mh.until(() => other.list(1).length === 3, "second context")
    expect(fetches(mh, Method.GET_SPACE_MEMBERS)).toBe(1)
    other.close()
  })

  it("keeps the list live: one member joining sends that member and their user, nothing else", async () => {
    const mh = await boot()
    mh.ui.subscribeTo(2, { kind: "spaceMembers", spaceId: space })
    await mh.until(() => mh.ui.list(2).length === 3 && roster(mh.ui, 2)?.loading === false, "roster")
    await mh.synced()
    const before = mh.ui.patches.length
    mh.model.addSpaceMember(SPACE, 4n)
    await mh.until(() => mh.ui.list(2).length === 4, "joined")
    const patches = mh.ui.patches.slice(before)
    const upserts = patches.flatMap((patch) => patch.rows).filter((change) => change.op === "upsert")
    expect(upserts.map((change) => (change.op === "upsert" ? `${change.row.kind}:${change.row.id}` : ""))).toEqual([
      `member:space:${space}:4`,
      "user:4",
    ])
    expect(patches.flatMap((patch) => patch.lists)).toEqual([
      { sub: 2, op: "splice", index: 3, remove: 0, insert: [rowKey("member", `space:${space}:4`)] },
    ])

    const leaving = mh.ui.patches.length
    mh.model.removeSpaceMember(SPACE, 3n)
    await mh.until(() => mh.ui.list(2).length === 3, "left")
    const removed = mh.ui.patches.slice(leaving).flatMap((patch) => patch.rows)
    expect(removed).toEqual(
      expect.arrayContaining([{ op: "remove", kind: "member", id: `space:${space}:3` }]),
    )
    expect(removed.filter((change) => change.op === "upsert")).toEqual([])
  })

  it("says the list is incomplete and failed when the fetch fails, and fetches again on the next subscribe", async () => {
    const mh = await boot()
    let failing = true
    mh.fail = (input) => (failing && input.oneofKind === "getSpaceMembers" ? RpcError_Code.INTERNAL_ERROR : undefined)
    mh.ui.subscribeTo(2, { kind: "spaceMembers", spaceId: space })
    await mh.until(() => roster(mh.ui, 2)?.failed === true, "failed")
    expect(roster(mh.ui, 2)).toMatchObject({ complete: false, loading: false })
    failing = false
    mh.ui.subscribeTo(3, { kind: "spaceMembers", spaceId: space })
    await mh.until(() => roster(mh.ui, 3)?.complete === true, "fetched again")
    expect(mh.ui.list(3)).toHaveLength(3)
  })
})

describe("chatParticipants", () => {
  it("lists group grants by name, then members by display name, from one fetch", async () => {
    const mh = await boot()
    mh.ui.subscribeTo(2, { kind: "chatParticipants", chatId: chat })
    await mh.until(() => roster(mh.ui, 2)?.complete === true && mh.ui.list(2).length === 3, "participants")
    expect(mh.ui.list(2)).toEqual([
      rowKey("userGroup", "900"),
      rowKey("member", `chat:${chat}:3`),
      rowKey("member", `chat:${chat}:2`),
    ])
    expect(mh.ui.state.rows.get(rowKey("userGroup", "900"))).toMatchObject({ name: "Designers", memberCount: 2 })
    expect(fetches(mh, Method.GET_CHAT_PARTICIPANTS)).toBe(1)
  })
})

describe("spaces and user groups", () => {
  it("lists the account's spaces by name, and a space's groups for group mentions", async () => {
    const mh = await boot()
    mh.ui.subscribeTo(2, { kind: "spaces" })
    await mh.until(() => mh.ui.list(2).length === 2, "spaces")
    expect((mh.ui.rows(2) as SpaceRow[]).map((row) => row.name)).toEqual(["Alpha", "Work"])
    expect(mh.ui.rows(2)[1]).toMatchObject({ creator: true })

    mh.ui.subscribeTo(3, { kind: "userGroups", spaceId: space })
    mh.ui.subscribeTo(4, { kind: "chatParticipants", chatId: chat })
    await mh.until(() => mh.ui.list(3).length === 1, "groups after the participants fetch stored one")
    expect(mh.ui.list(3)).toEqual([rowKey("userGroup", "900")])
    expect(self).toBe("1")
  })
})
