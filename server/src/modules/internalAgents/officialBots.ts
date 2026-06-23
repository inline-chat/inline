import { and, eq } from "drizzle-orm"
import { db } from "@in/server/db"
import { FileModel } from "@in/server/db/models/files"
import type { Transaction } from "@in/server/db/types"
import { botCommands, files, lower, users, type DbBotCommand, type DbFile, type DbUser } from "@in/server/db/schema"
import { decrypt } from "@in/server/modules/encryption/encryption"
import { uploadPhoto } from "@in/server/modules/files/uploadPhoto"
import { Log } from "@in/server/utils/log"
import { normalizeUsername } from "@in/server/utils/normalize"
import {
  INTERNAL_AGENT_REGISTRATIONS,
  type InternalAgentCommand,
  type InternalAgentProfilePhotoAsset,
  type InternalAgentRegistration,
} from "./aliases"

const log = new Log("internalAgents.officialBots")
const BOT_COMMAND_RE = /^[a-z0-9_]+$/

export type ProvisionedOfficialBot = {
  readonly agentKey: string
  readonly botUserId: number
  readonly username: string
}

export type ProvisionOfficialInternalBotsOptions = {
  readonly seedProfilePhotos?: boolean
}

export class OfficialInternalBotProvisionError extends Error {
  constructor(
    message: string,
    readonly agentKey: string,
  ) {
    super(message)
    this.name = "OfficialInternalBotProvisionError"
  }
}

export async function provisionOfficialInternalBots(
  registrations: readonly InternalAgentRegistration[] = INTERNAL_AGENT_REGISTRATIONS,
  options: ProvisionOfficialInternalBotsOptions = {},
): Promise<ProvisionedOfficialBot[]> {
  const provisioned: ProvisionedOfficialBot[] = []

  for (const registration of registrations) {
    provisioned.push(await provisionOfficialInternalBot(registration, options))
  }

  return provisioned
}

export async function getOfficialInternalBot(agentKey: string): Promise<ProvisionedOfficialBot | undefined> {
  const registration = INTERNAL_AGENT_REGISTRATIONS.find((candidate) => candidate.agentKey === agentKey)
  if (!registration) {
    return undefined
  }

  const username = normalizedUsername(registration.botUsername)
  const bot = await db._query.users.findFirst({
    where: eq(lower(users.username), username),
  })

  if (!bot || bot.deleted === true || bot.bot !== true || bot.botCreatorId !== null) {
    return undefined
  }

  return {
    agentKey,
    botUserId: bot.id,
    username,
  }
}

async function provisionOfficialInternalBot(
  registration: InternalAgentRegistration,
  options: ProvisionOfficialInternalBotsOptions,
): Promise<ProvisionedOfficialBot> {
  const username = normalizedUsername(registration.botUsername)
  const displayName = registration.displayName.trim()

  if (!username || !displayName) {
    throw new OfficialInternalBotProvisionError("Official bot registration has invalid identity", registration.agentKey)
  }

  const bot = await db.transaction(async (tx) => {
    const existing = await findUserByUsername(tx, username)

    if (existing) {
      ensureExistingOfficialBot(registration, existing)
      return updateOfficialBot(tx, existing.id, { username, displayName, agentKey: registration.agentKey })
    }

    return createOfficialBot(tx, { username, displayName, agentKey: registration.agentKey })
  })

  if (options.seedProfilePhotos !== false) {
    await seedOfficialBotProfilePhoto(bot, registration)
  }

  await syncOfficialBotCommands(bot.id, registration.commands, registration.agentKey)

  log.info("Provisioned official internal bot", {
    agentKey: registration.agentKey,
    botUserId: bot.id,
    username,
  })

  return {
    agentKey: registration.agentKey,
    botUserId: bot.id,
    username,
  }
}

async function seedOfficialBotProfilePhoto(bot: DbUser, registration: InternalAgentRegistration): Promise<void> {
  const asset = registration.profilePhotoAsset
  if (!asset) {
    return
  }

  if (bot.photoFileId !== null && !(await shouldReplaceProfilePhoto(bot.photoFileId, asset, registration.agentKey))) {
    return
  }

  try {
    const source = Bun.file(asset.url)
    const bytes = await source.arrayBuffer()
    const file = new File([bytes], asset.fileName, { type: asset.mimeType })
    const upload = await uploadPhoto(file, { userId: bot.id })
    const dbFile = await FileModel.getFileByUniqueId(upload.fileUniqueId)

    if (!dbFile) {
      log.warn("Official bot profile photo upload produced no file row", {
        agentKey: registration.agentKey,
        botUserId: bot.id,
        fileUniqueId: upload.fileUniqueId,
      })
      return
    }

    await db.update(users).set({ photoFileId: dbFile.id }).where(eq(users.id, bot.id))

    log.info("Seeded official bot profile photo", {
      agentKey: registration.agentKey,
      botUserId: bot.id,
      fileUniqueId: upload.fileUniqueId,
    })
  } catch (error) {
    log.warn("Failed to seed official bot profile photo", {
      error,
      agentKey: registration.agentKey,
      botUserId: bot.id,
      fileName: asset.fileName,
    })
  }
}

async function shouldReplaceProfilePhoto(
  photoFileId: number,
  asset: InternalAgentProfilePhotoAsset,
  agentKey: string,
): Promise<boolean> {
  const replaceNames = asset.replacesFileNames ?? []
  if (replaceNames.length === 0) {
    return false
  }

  const existing = await getFileById(photoFileId)
  if (!existing) {
    return false
  }

  const name = decryptFileName(existing, agentKey)
  return name ? replaceNames.includes(name) : false
}

async function getFileById(fileId: number): Promise<DbFile | undefined> {
  const [file] = await db.select().from(files).where(eq(files.id, fileId)).limit(1)
  return file
}

function decryptFileName(file: DbFile, agentKey: string): string | undefined {
  if (!file.nameEncrypted || !file.nameIv || !file.nameTag) {
    return undefined
  }

  try {
    return decrypt({
      encrypted: file.nameEncrypted,
      iv: file.nameIv,
      authTag: file.nameTag,
    })
  } catch (error) {
    log.warn("Failed to inspect official bot profile photo name", {
      error,
      agentKey,
      fileUniqueId: file.fileUniqueId,
    })
    return undefined
  }
}

async function findUserByUsername(tx: Transaction, username: string): Promise<DbUser | undefined> {
  const [row] = await tx.select().from(users).where(eq(lower(users.username), username)).limit(1)
  return row
}

function ensureExistingOfficialBot(registration: InternalAgentRegistration, user: DbUser): void {
  if (user.deleted === true) {
    throw new OfficialInternalBotProvisionError("Official bot username belongs to a deleted user row", registration.agentKey)
  }

  if (user.bot !== true) {
    throw new OfficialInternalBotProvisionError("Official bot username belongs to a non-bot user row", registration.agentKey)
  }

  if (user.botCreatorId !== null) {
    throw new OfficialInternalBotProvisionError("Official bot username belongs to a user-owned bot row", registration.agentKey)
  }
}

async function createOfficialBot(
  tx: Transaction,
  input: {
    readonly username: string
    readonly displayName: string
    readonly agentKey: string
  },
): Promise<DbUser> {
  const [row] = await tx
    .insert(users)
    .values({
      username: input.username,
      firstName: input.displayName,
      lastName: null,
      bot: true,
      botCreatorId: null,
      deleted: false,
      pendingSetup: false,
      emailVerified: false,
      phoneVerified: false,
    })
    .returning()

  if (!row) {
    throw new OfficialInternalBotProvisionError("Failed to create official bot user row", input.agentKey)
  }

  return row
}

async function updateOfficialBot(
  tx: Transaction,
  botUserId: number,
  input: {
    readonly username: string
    readonly displayName: string
    readonly agentKey: string
  },
): Promise<DbUser> {
  const [row] = await tx
    .update(users)
    .set({
      username: input.username,
      firstName: input.displayName,
      lastName: null,
      bot: true,
      botCreatorId: null,
      deleted: false,
      pendingSetup: false,
      emailVerified: false,
      phoneVerified: false,
    })
    .where(eq(users.id, botUserId))
    .returning()

  if (!row) {
    throw new OfficialInternalBotProvisionError("Failed to update official bot user row", input.agentKey)
  }

  return row
}

async function syncOfficialBotCommands(
  botUserId: number,
  commands: readonly InternalAgentCommand[],
  agentKey: string,
): Promise<DbBotCommand[]> {
  const desired = normalizeCommands(commands, agentKey)

  return db.transaction(async (tx) => {
    const existing = await tx.select().from(botCommands).where(eq(botCommands.botUserId, botUserId))
    const existingByCommand = new Map(existing.map((command) => [command.command, command]))
    const desiredNames = new Set(desired.map((command) => command.command))

    for (const command of desired) {
      const current = existingByCommand.get(command.command)

      if (!current) {
        await tx.insert(botCommands).values({
          botUserId,
          command: command.command,
          description: command.description,
          sortOrder: command.sortOrder,
          createdAt: new Date(),
          updatedAt: new Date(),
        })
        continue
      }

      if (current.description !== command.description || current.sortOrder !== command.sortOrder) {
        await tx
          .update(botCommands)
          .set({
            description: command.description,
            sortOrder: command.sortOrder,
            updatedAt: new Date(),
          })
          .where(and(eq(botCommands.botUserId, botUserId), eq(botCommands.command, command.command)))
      }
    }

    for (const command of existing) {
      if (!desiredNames.has(command.command)) {
        await tx
          .delete(botCommands)
          .where(and(eq(botCommands.botUserId, botUserId), eq(botCommands.command, command.command)))
      }
    }

    return tx
      .select()
      .from(botCommands)
      .where(eq(botCommands.botUserId, botUserId))
      .orderBy(botCommands.sortOrder, botCommands.command)
  })
}

function normalizeCommands(commands: readonly InternalAgentCommand[], agentKey: string) {
  const seen = new Set<string>()

  return commands.map((command, index) => {
    const name = command.command.trim().replace(/^\/+/, "")
    const description = command.description.trim()
    const sortOrder = command.sortOrder ?? index

    if (
      name.length < 1 ||
      name.length > 32 ||
      !BOT_COMMAND_RE.test(name) ||
      description.length < 1 ||
      description.length > 256 ||
      seen.has(name)
    ) {
      throw new OfficialInternalBotProvisionError("Official bot registration has invalid command metadata", agentKey)
    }

    seen.add(name)

    return {
      command: name,
      description,
      sortOrder,
    }
  })
}

function normalizedUsername(value: string): string {
  return normalizeUsername(value).toLowerCase()
}
