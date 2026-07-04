import type { SpaceSettings } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import type { Transaction } from "@in/server/db/types"
import { spaceSettings } from "@in/server/db/schema"
import { StoredSpaceSettings } from "@in/server/protocol/server"
import { Encryption2 } from "@in/server/modules/encryption/encryption2"
import { Log } from "@in/server/utils/log"
import { eq } from "drizzle-orm"

const log = new Log("SpaceSettingsModel")

type Stored = {
  spaceId: number
  gridEnabled: boolean
}

type Database = typeof db | Transaction

export const SpaceSettingsModel = {
  get,
  getStored,
  updateGrid,
}

async function get(spaceId: number, database: Database = db): Promise<SpaceSettings> {
  const stored = await getStored(spaceId, database)
  return encodeSettings(stored)
}

async function getStored(spaceId: number, database: Database = db): Promise<Stored> {
  const [row] = await database.select().from(spaceSettings).where(eq(spaceSettings.spaceId, spaceId)).limit(1)

  if (!row) {
    return defaultStored(spaceId)
  }

  try {
    const binary = Encryption2.decryptBinary(row.payload)
    const stored = StoredSpaceSettings.fromBinary(binary)
    return normalizeStored(spaceId, stored)
  } catch (error) {
    log.error("Failed to decrypt space settings", { spaceId, error })
    return defaultStored(spaceId)
  }
}

async function updateGrid(spaceId: number, enabled: boolean, database: Transaction): Promise<SpaceSettings> {
  const stored = await getStored(spaceId, database)
  const next: Stored = {
    ...stored,
    gridEnabled: enabled,
  }
  await saveStored(next, database)
  return encodeSettings(next)
}

async function saveStored(stored: Stored, database: Transaction) {
  const payload = Encryption2.encrypt(
    StoredSpaceSettings.toBinary({
      spaceId: BigInt(stored.spaceId),
      gridEnabled: stored.gridEnabled,
    }),
  )
  const updatedAt = new Date()

  await database
    .insert(spaceSettings)
    .values({
      spaceId: stored.spaceId,
      payload,
      updatedAt,
    })
    .onConflictDoUpdate({
      target: [spaceSettings.spaceId],
      set: {
        payload,
        updatedAt,
      },
    })
}

function encodeSettings(stored: Stored): SpaceSettings {
  return {
    spaceId: BigInt(stored.spaceId),
    gridEnabled: stored.gridEnabled,
  }
}

function normalizeStored(spaceId: number, stored: StoredSpaceSettings): Stored {
  return {
    spaceId,
    gridEnabled: stored.gridEnabled ?? false,
  }
}

function defaultStored(spaceId: number): Stored {
  return {
    spaceId,
    gridEnabled: false,
  }
}
