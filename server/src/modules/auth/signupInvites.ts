import { eq } from "drizzle-orm"
import { db } from "@in/server/db"
import { members, users, type DbUser } from "@in/server/db/schema"
import { InlineError } from "@in/server/types/errors"
import { InviteCodesModel, isValidInviteCode, normalizeInviteCode } from "@in/server/db/models/inviteCodes"
import { isInviteCodesRequired as isInviteCodesRequiredConfig } from "@in/server/env"

type Database = any

export const areInviteCodesRequired = async (): Promise<boolean> => {
  return isInviteCodesRequiredConfig()
}

export const isInviteCodeRequired = async (user: DbUser | undefined): Promise<boolean> => {
  if (!(await areInviteCodesRequired())) {
    return false
  }

  if (!user) {
    return true
  }

  if (user.pendingSetup !== true) {
    return false
  }

  return !(await hasSpaceMembership(user.id, db))
}

export const getOrCreateUserByEmailForSignup = async (
  email: string,
  inviteCode?: string,
): Promise<{ user: DbUser; created: boolean }> => {
  return await db.transaction(async (tx) => {
    const codesRequired = await areInviteCodesRequired()
    const user = (await tx.select().from(users).where(eq(users.email, email)).limit(1))[0]

    if (!user) {
      const code = codesRequired ? getInviteCode(inviteCode) : undefined

      const created = (
        await tx
          .insert(users)
          .values({
            email,
            emailVerified: true,
            pendingSetup: false,
          })
          .returning()
      )[0]

      if (!created) {
        throw new InlineError(InlineError.ApiError.INTERNAL)
      }

      if (code) {
        await redeemInviteCode(tx, code, created.id)
      }
      return { user: created, created: true }
    }

    const inviteRequired = codesRequired && user.pendingSetup === true && !(await hasSpaceMembership(user.id, tx))
    if (inviteRequired) {
      const code = getInviteCode(inviteCode)
      await redeemInviteCode(tx, code, user.id)
    }

    const updated = (
      await tx
        .update(users)
        .set({
          emailVerified: true,
          pendingSetup: false,
        })
        .where(eq(users.id, user.id))
        .returning()
    )[0]

    return { user: updated ?? user, created: false }
  })
}

export const getOrCreateUserByPhoneForSignup = async (
  phoneNumber: string,
  inviteCode?: string,
): Promise<{ user: DbUser; created: boolean }> => {
  return await db.transaction(async (tx) => {
    const codesRequired = await areInviteCodesRequired()
    const user = (await tx.select().from(users).where(eq(users.phoneNumber, phoneNumber)).limit(1))[0]

    if (!user) {
      const code = codesRequired ? getInviteCode(inviteCode) : undefined

      const created = (
        await tx
          .insert(users)
          .values({
            phoneNumber,
            phoneVerified: true,
            pendingSetup: false,
          })
          .returning()
      )[0]

      if (!created) {
        throw new InlineError(InlineError.ApiError.INTERNAL)
      }

      if (code) {
        await redeemInviteCode(tx, code, created.id)
      }
      return { user: created, created: true }
    }

    const inviteRequired = codesRequired && user.pendingSetup === true && !(await hasSpaceMembership(user.id, tx))
    if (inviteRequired) {
      const code = getInviteCode(inviteCode)
      await redeemInviteCode(tx, code, user.id)
    }

    const updated = (
      await tx
        .update(users)
        .set({
          phoneVerified: true,
          pendingSetup: false,
        })
        .where(eq(users.id, user.id))
        .returning()
    )[0]

    return { user: updated ?? user, created: false }
  })
}

const hasSpaceMembership = async (userId: number, database: Database): Promise<boolean> => {
  const row = (await database.select({ id: members.id }).from(members).where(eq(members.userId, userId)).limit(1))[0]
  return Boolean(row)
}

const getInviteCode = (inviteCode?: string): string => {
  if (!inviteCode?.trim()) {
    throw new InlineError(InlineError.ApiError.INVITE_CODE_REQUIRED)
  }

  if (!isValidInviteCode(inviteCode)) {
    throw new InlineError(InlineError.ApiError.INVITE_CODE_INVALID)
  }

  return normalizeInviteCode(inviteCode)
}

const redeemInviteCode = async (database: Database, inviteCode: string, userId: number) => {
  const redeemed = await InviteCodesModel.redeem({
    code: normalizeInviteCode(inviteCode),
    userId,
    tx: database,
  })

  if (!redeemed) {
    const existing = await InviteCodesModel.getByCode({ code: inviteCode, tx: database })
    throw new InlineError(
      existing?.redeemedAt ? InlineError.ApiError.INVITE_CODE_TAKEN : InlineError.ApiError.INVITE_CODE_NOT_FOUND,
    )
  }
}
