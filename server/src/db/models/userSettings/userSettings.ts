import { db } from "@in/server/db"
import {
  UserSettingsGeneralSchema,
  type UserSettingsGeneral,
  type UserSettingsGeneralInput,
} from "@in/server/db/models/userSettings/types"
import { decrypt, encrypt } from "@in/server/modules/encryption/encryption"
import { Log } from "@in/server/utils/log"
import { userSettings } from "@in/server/db/schema"

const log = new Log("UserSettingsModel")

/**
 * UserSettingsModel
 */
export const UserSettingsModel = {
  getGeneral,
  updateGeneral,
}

// Functions
async function getGeneral(userId: number): Promise<UserSettingsGeneral | null> {
  let result = await db.query.userSettings.findFirst({
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

  try {
    const decrypted = decrypt({
      encrypted: generalEncrypted,
      iv: generalIv,
      authTag: generalTag,
    })

    // decode JSON
    const general = UserSettingsGeneralSchema.safeParse(JSON.parse(decrypted))

    if (!general.success) {
      log.error("Failed to parse general settings", { userId, error: general.error })
      return null
    }

    // return
    return general.data
  } catch (error) {
    log.error("Failed to decrypt or parse general settings", { userId, error })
    return null
  }
}

async function updateGeneral(userId: number, general: UserSettingsGeneralInput): Promise<void> {
  // Validate the input data
  const validatedGeneral = UserSettingsGeneralSchema.parse(general)

  // Encrypt the settings
  const generalJson = JSON.stringify(validatedGeneral)
  const encryptedGeneral = encrypt(generalJson)

  // Insert or update the user settings
  await db
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

  log.debug("Updated general settings", { userId })
}
