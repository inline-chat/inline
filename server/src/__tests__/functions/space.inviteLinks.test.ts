import { describe, expect, test } from "bun:test"
import { db } from "@in/server/db"
import {
  members,
  spaceInviteLinks,
  spaceJoinBlocks,
  spaces,
} from "@in/server/db/schema"
import {
  getSpaceInviteLink,
  setSpaceInviteLinkEnabled,
} from "@in/server/functions/space.inviteLinks"
import { joinSpaceByInviteToken } from "@in/server/functions/space.joinByInviteToken"
import { joinPublicSpace } from "@in/server/functions/space.joinPublicSpace"
import { inviteToSpace } from "@in/server/functions/space.inviteToSpace"
import { deleteMemberHandler } from "@in/server/realtime/handlers/space.deleteMember"
import { hashSpaceInviteToken } from "@in/server/modules/spaces/spaceInviteLinks"
import { resolveSpaceJoinName } from "@in/server/controllers/extra/spaceJoinLive.effect"
import { handleRpcCall } from "@in/server/realtime/handlers/_rpc"
import { Method } from "@inline-chat/protocol/core"
import { and, eq } from "drizzle-orm"
import { setupTestLifecycle, testUtils } from "../setup"

const functionContext = (userId: number) => ({
  currentUserId: userId,
  currentSessionId: 1,
})

const handlerContext = (userId: number) => ({
  userId,
  sessionId: 1,
  connectionId: "space-invite-links-test",
  sendRaw: () => {},
  sendRpcReply: () => {},
})

describe("space invite links", () => {
  setupTestLifecycle()

  test("creates one encrypted seven-day private link and reuses it while active", async () => {
    const owner = await testUtils.createUser("invite-owner@example.com")
    const [space] = await db.insert(spaces).values({ name: "Private Team" }).returning()
    if (!space) throw new Error("Failed to create private space")
    await db.insert(members).values({ spaceId: space.id, userId: owner.id, role: "owner" })

    const [first, second] = await Promise.all([
      setSpaceInviteLinkEnabled(
        { spaceId: BigInt(space.id), enabled: true },
        functionContext(owner.id),
      ),
      setSpaceInviteLinkEnabled(
        { spaceId: BigInt(space.id), enabled: true },
        functionContext(owner.id),
      ),
    ])
    expect(first.link?.url).toBe(second.link?.url)
    expect(first.link?.expiresAt).toBeDefined()

    const token = new URL(first.link!.url).pathname.split("/").at(-1)!
    expect(token).toMatch(/^iv1_[A-Za-z0-9_-]{43}$/)
    const rows = await db.select().from(spaceInviteLinks).where(eq(spaceInviteLinks.spaceId, space.id))
    expect(rows).toHaveLength(1)
    expect(rows[0]!.tokenHash).toEqual(hashSpaceInviteToken(token))
    expect(rows[0]!.tokenEncrypted.toString("utf8")).not.toContain(token)
    const expiryDrift = Math.abs(
      rows[0]!.expiresAt.getTime() - rows[0]!.createdAt.getTime() - 7 * 24 * 60 * 60 * 1_000,
    )
    expect(expiryDrift).toBeLessThanOrEqual(1_000)

    const fetched = await getSpaceInviteLink(
      { spaceId: BigInt(space.id) },
      functionContext(owner.id),
    )
    expect(fetched.link).toEqual(first.link)
  })

  test("disabling a private link revokes it and enabling creates a different token", async () => {
    const owner = await testUtils.createUser("invite-rotate-owner@example.com")
    const teammate = await testUtils.createUser("invite-rotate-member@example.com")
    const [space] = await db.insert(spaces).values({ name: "Rotating Team" }).returning()
    if (!space) throw new Error("Failed to create private space")
    await db.insert(members).values({ spaceId: space.id, userId: owner.id, role: "owner" })

    const first = await setSpaceInviteLinkEnabled(
      { spaceId: BigInt(space.id), enabled: true },
      functionContext(owner.id),
    )
    const firstToken = new URL(first.link!.url).pathname.split("/").at(-1)!
    expect(await resolveSpaceJoinName({ kind: "invite_token", value: firstToken }))
      .toEqual({ name: "Rotating Team" })
    expect((await setSpaceInviteLinkEnabled(
      { spaceId: BigInt(space.id), enabled: false },
      functionContext(owner.id),
    )).link).toBeUndefined()
    expect((await getSpaceInviteLink(
      { spaceId: BigInt(space.id) },
      functionContext(owner.id),
    )).link).toBeUndefined()
    await expect(
      joinSpaceByInviteToken({ token: firstToken }, functionContext(teammate.id)),
    ).rejects.toMatchObject({ codeName: "SPACE_INVITE_INVALID" })
    expect(await resolveSpaceJoinName({ kind: "invite_token", value: firstToken })).toBeNull()

    const second = await setSpaceInviteLinkEnabled(
      { spaceId: BigInt(space.id), enabled: true },
      functionContext(owner.id),
    )
    expect(second.link?.url).not.toBe(first.link?.url)
  })

  test("treats expired private links as unavailable everywhere", async () => {
    const owner = await testUtils.createUser("invite-expired-owner@example.com")
    const teammate = await testUtils.createUser("invite-expired-member@example.com")
    const [space] = await db.insert(spaces).values({ name: "Expired Team" }).returning()
    if (!space) throw new Error("Failed to create private space")
    await db.insert(members).values({ spaceId: space.id, userId: owner.id, role: "owner" })

    const link = await setSpaceInviteLinkEnabled(
      { spaceId: BigInt(space.id), enabled: true },
      functionContext(owner.id),
    )
    const token = new URL(link.link!.url).pathname.split("/").at(-1)!
    await db
      .update(spaceInviteLinks)
      .set({
        createdAt: new Date(Date.now() - 2_000),
        expiresAt: new Date(Date.now() - 1_000),
      })
      .where(eq(spaceInviteLinks.spaceId, space.id))

    expect((await getSpaceInviteLink(
      { spaceId: BigInt(space.id) },
      functionContext(owner.id),
    )).link).toBeUndefined()
    expect(await resolveSpaceJoinName({ kind: "invite_token", value: token })).toBeNull()
    await expect(
      joinSpaceByInviteToken({ token }, functionContext(teammate.id)),
    ).rejects.toMatchObject({ codeName: "SPACE_INVITE_INVALID" })
  })

  test("allows only an admin or owner to manage a space link", async () => {
    const owner = await testUtils.createUser("invite-role-owner@example.com")
    const member = await testUtils.createUser("invite-role-member@example.com")
    const [space] = await db.insert(spaces).values({ name: "Managed Team" }).returning()
    if (!space) throw new Error("Failed to create private space")
    await db.insert(members).values([
      { spaceId: space.id, userId: owner.id, role: "owner" },
      { spaceId: space.id, userId: member.id, role: "member" },
    ])

    await expect(getSpaceInviteLink(
      { spaceId: BigInt(space.id) },
      functionContext(member.id),
    )).rejects.toMatchObject({ codeName: "SPACE_ADMIN_REQUIRED" })
    await expect(setSpaceInviteLinkEnabled(
      { spaceId: BigInt(space.id), enabled: true },
      functionContext(member.id),
    )).rejects.toMatchObject({ codeName: "SPACE_ADMIN_REQUIRED" })
  })

  test("dispatches private link administration and joining through all three RPC methods", async () => {
    const owner = await testUtils.createUser("invite-rpc-owner@example.com")
    const teammate = await testUtils.createUser("invite-rpc-member@example.com")
    const [space] = await db.insert(spaces).values({ name: "RPC Team" }).returning()
    if (!space) throw new Error("Failed to create private space")
    await db.insert(members).values({ spaceId: space.id, userId: owner.id, role: "owner" })

    const setResult = await handleRpcCall({
      method: Method.SET_SPACE_INVITE_LINK_ENABLED,
      input: {
        oneofKind: "setSpaceInviteLinkEnabled",
        setSpaceInviteLinkEnabled: { spaceId: BigInt(space.id), enabled: true },
      },
    }, handlerContext(owner.id))
    expect(setResult.oneofKind).toBe("setSpaceInviteLinkEnabled")
    if (setResult.oneofKind !== "setSpaceInviteLinkEnabled" || !setResult.setSpaceInviteLinkEnabled.link) {
      throw new Error("Expected enabled invite link")
    }
    const token = new URL(setResult.setSpaceInviteLinkEnabled.link.url).pathname.split("/").at(-1)!

    const getResult = await handleRpcCall({
      method: Method.GET_SPACE_INVITE_LINK,
      input: {
        oneofKind: "getSpaceInviteLink",
        getSpaceInviteLink: { spaceId: BigInt(space.id) },
      },
    }, handlerContext(owner.id))
    expect(getResult.oneofKind).toBe("getSpaceInviteLink")
    if (getResult.oneofKind !== "getSpaceInviteLink") throw new Error("Expected invite link")
    expect(getResult.getSpaceInviteLink.link?.url).toBe(setResult.setSpaceInviteLinkEnabled.link.url)

    const joinResult = await handleRpcCall({
      method: Method.JOIN_SPACE_BY_INVITE_TOKEN,
      input: {
        oneofKind: "joinSpaceByInviteToken",
        joinSpaceByInviteToken: { token },
      },
    }, handlerContext(teammate.id))
    expect(joinResult.oneofKind).toBe("joinSpaceByInviteToken")
    if (joinResult.oneofKind !== "joinSpaceByInviteToken") throw new Error("Expected joined space")
    if (!joinResult.joinSpaceByInviteToken.space) throw new Error("Expected joined space payload")
    expect(joinResult.joinSpaceByInviteToken.space.id).toBe(BigInt(space.id))
  })

  test("joins through a private token and enforces Block and Remove", async () => {
    const owner = await testUtils.createUser("invite-block-owner@example.com")
    const teammate = await testUtils.createUser("invite-block-member@example.com")
    const [space] = await db.insert(spaces).values({ name: "Blocked Team" }).returning()
    if (!space) throw new Error("Failed to create private space")
    await db.insert(members).values({ spaceId: space.id, userId: owner.id, role: "owner" })
    const link = await setSpaceInviteLinkEnabled(
      { spaceId: BigInt(space.id), enabled: true },
      functionContext(owner.id),
    )
    const token = new URL(link.link!.url).pathname.split("/").at(-1)!

    const joined = await joinSpaceByInviteToken({ token }, functionContext(teammate.id))
    expect(joined.alreadyMember).toBe(false)
    await deleteMemberHandler(
      { spaceId: BigInt(space.id), userId: BigInt(teammate.id), blockJoin: true },
      handlerContext(owner.id),
    )
    expect(await db.select().from(spaceJoinBlocks).where(and(
      eq(spaceJoinBlocks.spaceId, space.id),
      eq(spaceJoinBlocks.userId, teammate.id),
    ))).toHaveLength(1)
    await expect(
      joinSpaceByInviteToken({ token }, functionContext(teammate.id)),
    ).rejects.toMatchObject({ codeName: "SPACE_INVITE_INVALID" })
  })

  test("plain removal from a private space allows the member to use the link again", async () => {
    const owner = await testUtils.createUser("invite-remove-owner@example.com")
    const teammate = await testUtils.createUser("invite-remove-member@example.com")
    const [space] = await db.insert(spaces).values({ name: "Open Team" }).returning()
    if (!space) throw new Error("Failed to create private space")
    await db.insert(members).values({ spaceId: space.id, userId: owner.id, role: "owner" })
    const link = await setSpaceInviteLinkEnabled(
      { spaceId: BigInt(space.id), enabled: true },
      functionContext(owner.id),
    )
    const token = new URL(link.link!.url).pathname.split("/").at(-1)!
    await joinSpaceByInviteToken({ token }, functionContext(teammate.id))
    await deleteMemberHandler(
      { spaceId: BigInt(space.id), userId: BigInt(teammate.id), blockJoin: false },
      handlerContext(owner.id),
    )

    const joinedAgain = await joinSpaceByInviteToken({ token }, functionContext(teammate.id))
    expect(joinedAgain.alreadyMember).toBe(false)
  })

  test("an explicit administrator invite bypasses a private link join block", async () => {
    const owner = await testUtils.createUser("invite-bypass-owner@example.com")
    const teammate = await testUtils.createUser("invite-bypass-member@example.com")
    const [space] = await db.insert(spaces).values({ name: "Admin Bypass Team" }).returning()
    if (!space) throw new Error("Failed to create private space")
    await db.insert(members).values({ spaceId: space.id, userId: owner.id, role: "owner" })
    const link = await setSpaceInviteLinkEnabled(
      { spaceId: BigInt(space.id), enabled: true },
      functionContext(owner.id),
    )
    const token = new URL(link.link!.url).pathname.split("/").at(-1)!
    await joinSpaceByInviteToken({ token }, functionContext(teammate.id))
    await deleteMemberHandler(
      { spaceId: BigInt(space.id), userId: BigInt(teammate.id), blockJoin: true },
      handlerContext(owner.id),
    )

    await expect(
      joinSpaceByInviteToken({ token }, functionContext(teammate.id)),
    ).rejects.toMatchObject({ codeName: "SPACE_INVITE_INVALID" })
    const invited = await inviteToSpace({
      spaceId: BigInt(space.id),
      role: { role: { oneofKind: "member", member: { canAccessPublicChats: true } } },
      via: { oneofKind: "userId", userId: BigInt(teammate.id) },
    }, functionContext(owner.id))
    expect(invited.member?.userId).toBe(BigInt(teammate.id))
  })

  test("returns and toggles the stable public handle link without creating token rows", async () => {
    const owner = await testUtils.createUser("public-link-owner@example.com")
    const [space] = await db.insert(spaces).values({
      name: "Town Hall",
      handle: "TownHall",
      isPublic: true,
    }).returning()
    if (!space) throw new Error("Failed to create public space")
    await db.insert(members).values({ spaceId: space.id, userId: owner.id, role: "owner" })

    expect((await getSpaceInviteLink(
      { spaceId: BigInt(space.id) },
      functionContext(owner.id),
    )).link).toBeUndefined()
    expect(await resolveSpaceJoinName({ kind: "public_handle", value: "TownHall" })).toBeNull()
    const enabled = await setSpaceInviteLinkEnabled(
      { spaceId: BigInt(space.id), enabled: true },
      functionContext(owner.id),
    )
    expect(enabled.link).toEqual({ url: "https://inline.chat/s/TownHall" })
    expect(await resolveSpaceJoinName({ kind: "public_handle", value: "@townhall" }))
      .toEqual({ name: "Town Hall" })
    expect(await db.select().from(spaceInviteLinks)).toHaveLength(0)
    expect((await setSpaceInviteLinkEnabled(
      { spaceId: BigInt(space.id), enabled: false },
      functionContext(owner.id),
    )).link).toBeUndefined()
  })

  test("public removal blocks re-entry through the public link", async () => {
    const owner = await testUtils.createUser("public-block-owner@example.com")
    const teammate = await testUtils.createUser("public-block-member@example.com")
    const [space] = await db.insert(spaces).values({
      name: "Public Block Team",
      handle: "public-block-team",
      isPublic: true,
      canPublicJoin: true,
    }).returning()
    if (!space) throw new Error("Failed to create public space")
    await db.insert(members).values([
      { spaceId: space.id, userId: owner.id, role: "owner" },
      { spaceId: space.id, userId: teammate.id, role: "member" },
    ])

    await deleteMemberHandler(
      { spaceId: BigInt(space.id), userId: BigInt(teammate.id), blockJoin: false },
      handlerContext(owner.id),
    )
    await expect(
      joinPublicSpace({ handle: "public-block-team" }, functionContext(teammate.id)),
    ).rejects.toMatchObject({ codeName: "SPACE_INVITE_INVALID" })
  })

  test("does not expose or enable links for reserved public handles", async () => {
    const owner = await testUtils.createUser("public-reserved-owner@example.com")
    const [space] = await db.insert(spaces).values({
      name: "Reserved Handle Team",
      handle: "admin",
      isPublic: true,
    }).returning()
    if (!space) throw new Error("Failed to create public space")
    await db.insert(members).values({ spaceId: space.id, userId: owner.id, role: "owner" })

    expect((await getSpaceInviteLink(
      { spaceId: BigInt(space.id) },
      functionContext(owner.id),
    )).link).toBeUndefined()
    expect(await resolveSpaceJoinName({ kind: "public_handle", value: "admin" })).toBeNull()
    await expect(setSpaceInviteLinkEnabled(
      { spaceId: BigInt(space.id), enabled: true },
      functionContext(owner.id),
    )).rejects.toMatchObject({ codeName: "SPACE_INVITE_INVALID" })
  })
})
