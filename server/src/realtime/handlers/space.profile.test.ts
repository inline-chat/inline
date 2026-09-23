import { describe, expect, spyOn, test } from "bun:test"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { db } from "@in/server/db"
import { files, members, spaces, updates } from "@in/server/db/schema"
import { eq } from "drizzle-orm"
import { createSpaceV3 } from "./v3Migration"
import { setSpacePhotoHandler } from "./space.profile"
import { Sync } from "@in/server/modules/updates/sync"
import type { HandlerContext } from "@in/server/realtime/types"
import { InlineError } from "@in/server/types/errors"
import * as mediaPaths from "@in/server/modules/files/path"

const context = (userId: number, sessionId: number): HandlerContext => ({
  userId, sessionId, connectionId: "space-profile-test", sendRaw: () => {}, sendRpcReply: () => {},
})

async function account(email: string) {
  const user = await testUtils.createUser(email)
  const session = await testUtils.createSessionForUser(user.id)
  return { user, ctx: context(user.id, session.session.id) }
}
async function photo(userId: number, suffix: string, fileType: "photo" | "document" = "photo") {
  const [file] = await db.insert(files).values({ userId, fileUniqueId: `space_photo_${suffix}`, fileType }).returning()
  if (!file) throw new Error("missing test file")
  return file.fileUniqueId
}

describe("space profile pictures", () => {
  setupTestLifecycle()

  test("creation attaches an owned photo and leaves Pro disabled", async () => {
    const owner = await account("space-owner@example.com")
    const id = await photo(owner.user.id, "create")
    const result = await createSpaceV3({ name: "Design", photoFileUniqueId: id }, owner.ctx)
    expect(result.space?.photoFileUniqueId).toBe(id)
    expect(result.space?.isPro).toBe(false)
    const stored = await db.select().from(spaces).where(eq(spaces.id, Number(result.space!.id)))
    expect(stored[0]?.photoFileUniqueId).toBe(id)
  })

  test("rejects another user's image and non-images before creating a space", async () => {
    const owner = await account("space-owner@example.com")
    const other = await account("space-other@example.com")
    const otherPhoto = await photo(other.user.id, "other")
    const document = await photo(owner.user.id, "doc", "document")
    await expect(createSpaceV3({ name: "Rejected", photoFileUniqueId: otherPhoto }, owner.ctx)).rejects.toThrow()
    await expect(createSpaceV3({ name: "Rejected", photoFileUniqueId: document }, owner.ctx)).rejects.toThrow()
    expect(await db.select().from(spaces)).toHaveLength(0)
  })

  test("owner replaces and removes the picture with durable space updates", async () => {
    const owner = await account("space-owner@example.com")
    const created = await createSpaceV3({ name: "Design" }, owner.ctx)
    const spaceId = created.space!.id
    const id = await photo(owner.user.id, "replace")
    const changed = await setSpacePhotoHandler({ spaceId, fileUniqueId: id }, owner.ctx)
    expect(changed.space?.photoFileUniqueId).toBe(id)
    expect(changed.updates[0]?.update.oneofKind).toBe("spaceProfile")
    const removed = await setSpacePhotoHandler({ spaceId, fileUniqueId: "" }, owner.ctx)
    expect(removed.space?.photoFileUniqueId).toBeUndefined()
    expect(removed.space?.photoUrl).toBeUndefined()
    expect(removed.updates[0]!.seq).toBeGreaterThan(changed.updates[0]!.seq!)
    const rows = await db.select().from(updates).where(eq(updates.entityId, Number(spaceId)))
    const inflated = Sync.inflateSpaceUpdates(rows)
    expect(inflated.filter(value => value.update.oneofKind === "spaceProfile")).toHaveLength(2)
  })

  test("admins may edit; regular members, guests, and outsiders may not", async () => {
    const owner = await account("space-owner@example.com")
    const editor = await account("space-editor@example.com")
    const created = await createSpaceV3({ name: "Design" }, owner.ctx)
    const spaceId = created.space!.id
    const id = await photo(editor.user.id, "admin")
    await expect(setSpacePhotoHandler({ spaceId, fileUniqueId: id }, editor.ctx)).rejects.toThrow()
    const [member] = await db.insert(members).values({ spaceId: Number(spaceId), userId: editor.user.id, role: "member", canAccessPublicChats: false }).returning()
    await expect(setSpacePhotoHandler({ spaceId, fileUniqueId: id }, editor.ctx)).rejects.toThrow()
    await db.update(members).set({ canAccessPublicChats: true }).where(eq(members.id, member!.id))
    await expect(setSpacePhotoHandler({ spaceId, fileUniqueId: id }, editor.ctx)).rejects.toThrow()
    await db.update(members).set({ role: "admin" }).where(eq(members.id, member!.id))
    expect((await setSpacePhotoHandler({ spaceId, fileUniqueId: id }, editor.ctx)).space?.photoFileUniqueId).toBe(id)
  })

  test("photo edits cannot change an existing Pro entitlement", async () => {
    const owner = await account("space-owner@example.com")
    const created = await createSpaceV3({ name: "Design" }, owner.ctx)
    const spaceId = created.space!.id
    await db.update(spaces).set({ isPro: true }).where(eq(spaces.id, Number(spaceId)))
    const result = await setSpacePhotoHandler({ spaceId, fileUniqueId: "" }, owner.ctx)
    expect(result.space?.isPro).toBe(true)
  })

  test("invalid replacement leaves the existing picture and sequence untouched", async () => {
    const owner = await account("space-owner@example.com")
    const other = await account("space-other@example.com")
    const original = await photo(owner.user.id, "original")
    const created = await createSpaceV3({ name: "Design", photoFileUniqueId: original }, owner.ctx)
    const spaceId = created.space!.id
    const invalidPhotos = [
      "missing_photo",
      await photo(other.user.id, "foreign"),
      await photo(owner.user.id, "document", "document"),
    ]
    for (const fileUniqueId of invalidPhotos) {
      await expect(setSpacePhotoHandler({ spaceId, fileUniqueId }, owner.ctx)).rejects.toBeInstanceOf(InlineError)
    }
    const [stored] = await db.select().from(spaces).where(eq(spaces.id, Number(spaceId)))
    expect(stored?.photoFileUniqueId).toBe(original)
    expect(stored?.updateSeq).toBe(created.space!.seq)
  })

  test("deleted and invalid spaces reject picture changes", async () => {
    const owner = await account("space-owner@example.com")
    const created = await createSpaceV3({ name: "Design" }, owner.ctx)
    const spaceId = created.space!.id
    await db.update(spaces).set({ deleted: new Date() }).where(eq(spaces.id, Number(spaceId)))
    for (const rejectedId of [spaceId, 0n, -1n, 9_007_199_254_740_992n]) {
      await expect(setSpacePhotoHandler({ spaceId: rejectedId, fileUniqueId: "" }, owner.ctx)).rejects.toThrow()
    }
  })

  test("replayed pictures receive a fresh URL and removals keep it absent", async () => {
    const owner = await account("space-owner@example.com")
    const created = await createSpaceV3({ name: "Design" }, owner.ctx)
    const spaceId = created.space!.id
    const id = await photo(owner.user.id, "replay")
    await setSpacePhotoHandler({ spaceId, fileUniqueId: id }, owner.ctx)
    await setSpacePhotoHandler({ spaceId, fileUniqueId: "" }, owner.ctx)
    const rows = await db.select().from(updates).where(eq(updates.entityId, Number(spaceId)))
    // The isolated test runner intentionally supplies no production media secrets.
    const sign = mediaPaths.getSignedMediaFileProxyUrl
    const signer = spyOn(mediaPaths, "getSignedMediaFileProxyUrl").mockImplementation(file => sign(file, 60, {
      signingKey: "space-profile-test-key", baseUrl: "https://example.com", now: 2_000,
    }))
    try {
      const profiles = Sync.inflateSpaceUpdates(rows)
        .flatMap(value => value.update.oneofKind === "spaceProfile" ? [value.update.spaceProfile] : [])
      const withPhoto = profiles.find(value => value.photoFileUniqueId === id)
      expect(withPhoto?.photoUrl).toBeDefined()
      const url = new URL(withPhoto!.photoUrl!)
      expect(url.searchParams.get("id")).toBe(id)
      expect(url.searchParams.get("exp")).toBe("2060")
      const removal = profiles.find(value => value.photoFileUniqueId === undefined)
      expect(removal).toBeDefined()
      expect(removal?.photoUrl).toBeUndefined()
    } finally {
      signer.mockRestore()
    }
  })

  test("owners and admins can replace and remove pictures on both free and Pro spaces", async () => {
    const owner = await account("space-owner@example.com")
    const admin = await account("space-admin@example.com")
    const ownerPhoto = await photo(owner.user.id, "owner-matrix")
    const adminPhoto = await photo(admin.user.id, "admin-matrix")
    for (const isPro of [false, true]) {
      const created = await createSpaceV3({ name: "Photo permissions" }, owner.ctx)
      const spaceId = created.space!.id
      await db.update(spaces).set({ isPro }).where(eq(spaces.id, Number(spaceId)))
      await db.insert(members).values({ spaceId: Number(spaceId), userId: admin.user.id, role: "admin" })
      for (const [actor, fileUniqueId] of [[owner, ownerPhoto], [admin, adminPhoto]] as const) {
        const added = await setSpacePhotoHandler({ spaceId, fileUniqueId }, actor.ctx)
        expect(added.space?.photoFileUniqueId).toBe(fileUniqueId)
        expect(added.space?.isPro).toBe(isPro)
        const removed = await setSpacePhotoHandler({ spaceId, fileUniqueId: "" }, actor.ctx)
        expect(removed.space?.photoFileUniqueId).toBeUndefined()
        expect(removed.space?.photoUrl).toBeUndefined()
        expect(removed.space?.isPro).toBe(isPro)
        expect(removed.updates[0]!.seq).toBeGreaterThan(added.updates[0]!.seq!)
      }
    }
  })

  test("unauthorized replacement and removal do not mutate the picture or sequence", async () => {
    const owner = await account("space-owner@example.com")
    const outsider = await account("space-outsider@example.com")
    const member = await account("space-member@example.com")
    const guest = await account("space-guest@example.com")
    const original = await photo(owner.user.id, "protected")
    const created = await createSpaceV3({ name: "Protected", photoFileUniqueId: original }, owner.ctx)
    const spaceId = created.space!.id
    await db.insert(members).values([
      { spaceId: Number(spaceId), userId: member.user.id, role: "member", canAccessPublicChats: true },
      { spaceId: Number(spaceId), userId: guest.user.id, role: "member", canAccessPublicChats: false },
    ])
    for (const actor of [outsider, member, guest]) {
      const replacement = await photo(actor.user.id, `denied_${actor.user.id}`)
      for (const fileUniqueId of [replacement, ""]) {
        await expect(setSpacePhotoHandler({ spaceId, fileUniqueId }, actor.ctx)).rejects.toThrow()
        const [stored] = await db.select().from(spaces).where(eq(spaces.id, Number(spaceId)))
        expect(stored?.photoFileUniqueId).toBe(original)
        expect(stored?.updateSeq).toBe(created.space!.seq)
        expect(stored?.isPro).toBe(false)
      }
    }
  })

})
