import { db } from "@in/server/db"
import { members, spaceInviteLinks, spaces } from "@in/server/db/schema"
import type { Transaction } from "@in/server/db/types"
import type { FunctionContext } from "@in/server/functions/_types"
import {
  decryptSpaceInviteToken,
  encryptSpaceInviteToken,
  generateSpaceInviteToken,
  hashSpaceInviteToken,
  isValidPublicJoinHandle,
  privateSpaceInviteUrl,
  publicSpaceInviteUrl,
  SPACE_INVITE_DEFAULT_EXPIRY_MS,
} from "@in/server/modules/spaces/spaceInviteLinks"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { isValidSpaceId } from "@in/server/utils/validate"
import type {
  GetSpaceInviteLinkInput,
  GetSpaceInviteLinkResult,
  SetSpaceInviteLinkEnabledInput,
  SetSpaceInviteLinkEnabledResult,
  SpaceInviteLink,
} from "@inline-chat/protocol/core"
import { and, eq, gt, inArray, isNull } from "drizzle-orm"

const requireSpaceId = (value: bigint): number => {
  const spaceId = Number(value)
  if (!isValidSpaceId(spaceId)) throw RealtimeRpcError.SpaceIdInvalid()
  return spaceId
}

const encodedPrivateLink = (row: typeof spaceInviteLinks.$inferSelect): SpaceInviteLink => ({
  url: privateSpaceInviteUrl(decryptSpaceInviteToken(row.tokenEncrypted)),
  expiresAt: BigInt(Math.floor(row.expiresAt.getTime() / 1_000)),
})

const requireAdmin = async (
  tx: Transaction,
  spaceId: number,
  currentUserId: number,
): Promise<void> => {
  const [membership] = await tx
    .select({ role: members.role })
    .from(members)
    .where(and(
      eq(members.spaceId, spaceId),
      eq(members.userId, currentUserId),
      inArray(members.role, ["admin", "owner"]),
    ))
    .limit(1)
  if (!membership) throw RealtimeRpcError.SpaceAdminRequired()
}

export const getSpaceInviteLink = async (
  input: GetSpaceInviteLinkInput,
  context: FunctionContext,
): Promise<GetSpaceInviteLinkResult> => {
  const spaceId = requireSpaceId(input.spaceId)
  return db.transaction(async (tx) => {
    const [space] = await tx
      .select()
      .from(spaces)
      .where(and(eq(spaces.id, spaceId), isNull(spaces.deleted)))
      .limit(1)
    if (!space) throw RealtimeRpcError.SpaceIdInvalid()
    await requireAdmin(tx, spaceId, context.currentUserId)

    if (space.isPublic) {
      const handle = space.handle
      return {
        link: space.canPublicJoin && handle && isValidPublicJoinHandle(handle)
          ? { url: publicSpaceInviteUrl(handle) }
          : undefined,
      }
    }

    const [active] = await tx
      .select()
      .from(spaceInviteLinks)
      .where(and(
        eq(spaceInviteLinks.spaceId, spaceId),
        isNull(spaceInviteLinks.revokedAt),
        gt(spaceInviteLinks.expiresAt, new Date()),
      ))
      .limit(1)
    return { link: active ? encodedPrivateLink(active) : undefined }
  })
}

export const setSpaceInviteLinkEnabled = async (
  input: SetSpaceInviteLinkEnabledInput,
  context: FunctionContext,
): Promise<SetSpaceInviteLinkEnabledResult> => {
  const spaceId = requireSpaceId(input.spaceId)
  return db.transaction(async (tx) => {
    const [space] = await tx
      .select()
      .from(spaces)
      .where(and(eq(spaces.id, spaceId), isNull(spaces.deleted)))
      .for("update")
      .limit(1)
    if (!space) throw RealtimeRpcError.SpaceIdInvalid()
    await requireAdmin(tx, spaceId, context.currentUserId)

    if (space.isPublic) {
      const handle = space.handle
      if (input.enabled && (!handle || !isValidPublicJoinHandle(handle))) {
        throw RealtimeRpcError.SpaceInviteInvalid()
      }
      await tx
        .update(spaces)
        .set({ canPublicJoin: input.enabled })
        .where(eq(spaces.id, spaceId))
      return {
        link: input.enabled && handle ? { url: publicSpaceInviteUrl(handle) } : undefined,
      }
    }

    const now = new Date()
    const [active] = await tx
      .select()
      .from(spaceInviteLinks)
      .where(and(eq(spaceInviteLinks.spaceId, spaceId), isNull(spaceInviteLinks.revokedAt)))
      .for("update")
      .limit(1)

    if (!input.enabled) {
      if (active) {
        await tx
          .update(spaceInviteLinks)
          .set({ revokedAt: now })
          .where(eq(spaceInviteLinks.id, active.id))
      }
      return { link: undefined }
    }

    if (active && active.expiresAt > now) {
      return { link: encodedPrivateLink(active) }
    }
    if (active) {
      await tx
        .update(spaceInviteLinks)
        .set({ revokedAt: now })
        .where(eq(spaceInviteLinks.id, active.id))
    }

    const token = generateSpaceInviteToken()
    const expiresAt = new Date(now.getTime() + SPACE_INVITE_DEFAULT_EXPIRY_MS)
    const [created] = await tx
      .insert(spaceInviteLinks)
      .values({
        spaceId,
        tokenHash: hashSpaceInviteToken(token),
        tokenEncrypted: encryptSpaceInviteToken(token),
        createdByUserId: context.currentUserId,
        expiresAt,
      })
      .returning()
    if (!created) throw RealtimeRpcError.InternalError()
    return { link: encodedPrivateLink(created) }
  })
}
