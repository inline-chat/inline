import type { SpaceSettings } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import type { Transaction } from "@in/server/db/types"
import { spaceSettings } from "@in/server/db/schema"
import { StoredSpaceSettings } from "@in/server/protocol/server"
import { Encryption2 } from "@in/server/modules/encryption/encryption2"
import { Log } from "@in/server/utils/log"
import { eq, inArray } from "drizzle-orm"

const log = new Log("SpaceSettingsModel")

type Stored = {
  spaceId: number
  gridEnabled: boolean
}

type Database = typeof db | Transaction

export const SpaceSettingsModel = {
  get,
  getStored,
  getStoredMany,
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

  return decodeStored(spaceId, row.payload)
}

async function getStoredMany(spaceIds: number[], database: Database = db): Promise<Stored[]> {
  const uniqueSpaceIds = [...new Set(spaceIds)]
  if (uniqueSpaceIds.length === 0) return []
  const rows = await database.select().from(spaceSettings).where(inArray(spaceSettings.spaceId, uniqueSpaceIds))
  const rowsBySpaceId = new Map(rows.map((row) => [row.spaceId, row]))
  return uniqueSpaceIds.map((spaceId) => {
    const row = rowsBySpaceId.get(spaceId)
    return row ? decodeStored(spaceId, row.payload) : defaultStored(spaceId)
  })
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

function decodeStored(spaceId: number, payload: Buffer): Stored {
  try {
    const binary = Encryption2.decryptBinary(payload)
    return normalizeStored(spaceId, StoredSpaceSettings.fromBinary(binary))
  } catch (error) {
    log.error("Failed to decrypt space settings", { spaceId, error })
    return defaultStored(spaceId)
  }
}

function defaultStored(spaceId: number): Stored {
  return {
    spaceId,
    gridEnabled: false,
  }
}
