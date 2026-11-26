import { db } from "@in/server/db"
import {
  UserSettingsGeneralSchema,
  type UserSettingsGeneral,
  type UserSettingsGeneralInput,
} from "@in/server/db/models/userSettings/types"
import { normalizeUserSettingsGeneral } from "@in/server/modules/notifications/notificationSettingsCompat"
import { decrypt, encrypt } from "@in/server/modules/encryption/encryption"
import { Log } from "@in/server/utils/log"
import { userSettings, users } from "@in/server/db/schema"
import { eq, inArray } from "drizzle-orm"
import type { Transaction } from "@in/server/db/types"
import { effectiveTimeZoneRule, isPublicRule, mergePrivacyPatch } from "@in/server/modules/privacy/privacyRules"
import { latestLiveDeviceTimeZone } from "@in/server/modules/users/timeZoneSync"

const log = new Log("UserSettingsModel")

/**
 * UserSettingsModel
 */
export const UserSettingsModel = {
  getGeneral,
  getGeneralForUsers,
  updateGeneral,
  updateGeneralWithPatch,
}

// Functions
async function getGeneral(userId: number): Promise<UserSettingsGeneral | null> {
  const result = await db.query.userSettings.findFirst({
    where: {
      userId,
    },
  })

  if (!result) {
    return null
  }

  // decrypt
  const generalEncrypted = result?.generalEncrypted
  const generalIv = result?.generalIv
  const generalTag = result?.generalTag

  if (!generalEncrypted || !generalIv || !generalTag) {
    return null
  }

  return decodeGeneral({ generalEncrypted, generalIv, generalTag }, userId)
}

/** Read privacy settings in the caller's snapshot without checking out another connection. */
async function getGeneralForUsers(tx: Transaction, userIds: number[]): Promise<Map<number, UserSettingsGeneral | null>> {
  if (userIds.length === 0) return new Map()
  const rows = await tx.select().from(userSettings).where(inArray(userSettings.userId, userIds))
  return new Map(rows.map(row => [row.userId, decodeGeneral(row, row.userId)]))
}

async function updateGeneral(userId: number, general: UserSettingsGeneralInput): Promise<UserSettingsGeneral> {
  // Validate the input data
  const validatedGeneral = normalizeUserSettingsGeneral(
    UserSettingsGeneralSchema.parse({ ...general, privacy: mergePrivacyPatch(undefined, general.privacy, userId) }),
  )

  // Encrypt the settings
  const generalJson = JSON.stringify(validatedGeneral)

  const encryptedGeneral = encrypt(generalJson)

  // Insert or update the user settings
  await db.transaction(async (tx) => {
    await tx.select({ id: users.id }).from(users).where(eq(users.id, userId)).for("update").limit(1)
    await writeGeneral(tx, userId, validatedGeneral, encryptedGeneral)
  })

  log.debug("Updated general settings", { userId })

  return validatedGeneral
}

/**
 * Merge a partial settings update while holding the user's row lock.
 *
 * The user row is the owner for settings writes, including the first write
 * before a user_settings row exists. This makes concurrent partial updates
 * from different connections observe and merge the latest committed value.
 */
async function updateGeneralWithPatch(
  userId: number,
  input: UserSettingsGeneralInput,
  options?: { tx?: Transaction },
): Promise<{ general: UserSettingsGeneral; changed: boolean }> {
  const result = options?.tx
    ? await updateGeneralWithPatchInTransaction(options.tx, userId, input)
    : await db.transaction(async (tx) => updateGeneralWithPatchInTransaction(tx, userId, input))

  log.debug("Updated general settings", { userId, changed: result.changed })
  return result
}

async function updateGeneralWithPatchInTransaction(
  tx: Transaction,
  userId: number,
  input: UserSettingsGeneralInput,
): Promise<{ general: UserSettingsGeneral; changed: boolean }> {
  await tx.select({ id: users.id }).from(users).where(eq(users.id, userId)).for("update").limit(1)

  const [stored] = await tx.select().from(userSettings).where(eq(userSettings.userId, userId)).limit(1)
  const current = stored ? decodeGeneral(stored, userId) : null
  const next = normalizeUserSettingsGeneral(
    UserSettingsGeneralSchema.parse({
      messageGestures: current?.messageGestures || input.messageGestures
        ? { ...current?.messageGestures, ...input.messageGestures }
        : undefined,
      notifications: {
        ...current?.notifications,
        ...input.notifications,
      },
      privacy: mergePrivacyPatch(current?.privacy, input.privacy, userId),
      compose: {
        ...current?.compose,
        ...input.compose,
      },
    }),
  )

  if (current && JSON.stringify(current) === JSON.stringify(next)) {
    return { general: current, changed: false }
  }

  const encryptedGeneral = encrypt(JSON.stringify(next))
  await writeGeneral(tx, userId, next, encryptedGeneral)
  await applyManualTimeZone(tx, userId, current?.privacy.manualTimeZone, next.privacy.manualTimeZone)
  return { general: next, changed: true }
}

/**
 * A manual time zone becomes the user's time zone. Going back to automatic
 * restores the zone that most recently took effect on a live Apple device.
 */
async function applyManualTimeZone(
  tx: Transaction,
  userId: number,
  previous: string | undefined,
  next: string | undefined,
): Promise<void> {
  if (previous === next) return
  const timeZone = next ?? (await latestLiveDeviceTimeZone(tx, userId))?.timeZone
  if (!timeZone) return
  await tx.update(users).set({ timeZone }).where(eq(users.id, userId))
}

function decodeGeneral(
  row: Pick<typeof userSettings.$inferSelect, "generalEncrypted" | "generalIv" | "generalTag">,
  userId: number,
): UserSettingsGeneral | null {
  const { generalEncrypted, generalIv, generalTag } = row
  if (!generalEncrypted || !generalIv || !generalTag) {
    return null
  }

  try {
    const decrypted = decrypt({
      encrypted: generalEncrypted,
      iv: generalIv,
      authTag: generalTag,
    })

    const general = UserSettingsGeneralSchema.safeParse(JSON.parse(decrypted))
    if (!general.success) {
      log.error("Failed to parse general settings", { userId, error: general.error })
      return null
    }

    return normalizeUserSettingsGeneral(general.data)
  } catch (error) {
    log.error("Failed to decrypt or parse general settings", { userId, error })
    return null
  }
}

async function writeGeneral(
  tx: Transaction,
  userId: number,
  validatedGeneral: UserSettingsGeneral,
  encryptedGeneral: ReturnType<typeof encrypt>,
): Promise<void> {
  await tx
    .insert(userSettings)
    .values({
      userId,
      generalEncrypted: encryptedGeneral.encrypted,
      generalIv: encryptedGeneral.iv,
      generalTag: encryptedGeneral.authTag,
    })
    .onConflictDoUpdate({
      target: [userSettings.userId],
      set: {
        generalEncrypted: encryptedGeneral.encrypted,
        generalIv: encryptedGeneral.iv,
        generalTag: encryptedGeneral.authTag,
      },
    })

  await tx
    .update(users)
    .set({
      // Viewer-blind paths may show the time zone only when nobody is excluded.
      shareTimeZone: isPublicRule(effectiveTimeZoneRule(validatedGeneral.privacy)),
      appearInGlobalSearch: validatedGeneral.privacy.appearInGlobalSearch,
    })
    .where(eq(users.id, userId))
}
