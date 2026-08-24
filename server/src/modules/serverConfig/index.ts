import { and, eq, sql } from "drizzle-orm"
import { db } from "@in/server/db"
import { serverConfig, type DbServerConfig } from "@in/server/db/schema"
import { Log } from "@in/server/utils/log"

export const SERVER_CONFIG_KEYS = [
  "auth.signup_mode",
  "agents.rollout",
  "email.default_provider",
] as const

export type ServerConfigKey = (typeof SERVER_CONFIG_KEYS)[number]
export type SignupMode = "open" | "invite_only" | "disabled"
export type AgentsRollout = "disabled" | "enabled"
export type EmailProvider = "ses" | "resend"
export interface ServerConfigValueByKey {
  readonly "auth.signup_mode": SignupMode
  readonly "agents.rollout": AgentsRollout
  readonly "email.default_provider": EmailProvider
}
export type ServerConfigValue<K extends ServerConfigKey = ServerConfigKey> =
  ServerConfigValueByKey[K]
export type ServerConfigSource =
  | "server_override"
  | "environment"
  | "database"
  | "legacy_environment"
  | "default"

interface ServerConfigDefinition<K extends ServerConfigKey> {
  readonly key: K
  readonly label: string
  readonly description: string
  readonly environmentName: string
  readonly allowedValues: readonly string[]
  readonly defaultValue: ServerConfigValue<K>
  readonly legacyEnvironmentValue: () => ServerConfigValue<K> | null
}

export interface ResolvedServerConfig<K extends ServerConfigKey = ServerConfigKey> {
  readonly key: K
  readonly label: string
  readonly description: string
  readonly environmentName: string
  readonly allowedValues: readonly string[]
  readonly value: ServerConfigValue<K>
  readonly source: ServerConfigSource
  readonly databaseValue: ServerConfigValue<K> | null
  readonly databaseVersion: number | null
  readonly databaseUpdatedAt: string | null
  readonly databaseUpdatedByUserId: number | null
}

type ResolutionLayers = {
  readonly serverOverride?: unknown
  readonly environmentOverride?: unknown
  readonly databaseValue?: unknown
  readonly legacyEnvironmentValue?: unknown
}

const log = new Log("server.config")
const CACHE_TTL_MS = 5_000
const warnedInvalidLayers = new Set<string>()

const signupModes: readonly SignupMode[] = ["open", "invite_only", "disabled"]
const agentsRolloutValues: readonly AgentsRollout[] = ["disabled", "enabled"]
const emailProviders: readonly EmailProvider[] = ["ses", "resend"]

const legacySignupMode = (): SignupMode | null => {
  const value = process.env["INVITE_CODES_REQUIRED"]?.trim().toLowerCase()
  if (value === undefined) return null
  return value === "false" || value === "0" ? "open" : "invite_only"
}

const legacyEmailProvider = (): EmailProvider | null => {
  const value = process.env["EMAIL_PROVIDER"]?.trim().toLowerCase()
  return value === "ses" || value === "resend" ? value : null
}

const definitions: { readonly [K in ServerConfigKey]: ServerConfigDefinition<K> } = {
  "auth.signup_mode": {
    key: "auth.signup_mode",
    label: "New sign-ups",
    description: "Open sign-up, require an access invite, or stop creating new accounts while preserving login.",
    environmentName: "INLINE_CONFIG_AUTH_SIGNUP_MODE",
    allowedValues: signupModes,
    defaultValue: "invite_only",
    legacyEnvironmentValue: legacySignupMode,
  },
  "agents.rollout": {
    key: "agents.rollout",
    label: "Agents",
    description: "Controls the parked mentionable Agents API and activation path while the user experience remains unfinished.",
    environmentName: "INLINE_CONFIG_AGENTS_ROLLOUT",
    allowedValues: agentsRolloutValues,
    defaultValue: "disabled",
    legacyEnvironmentValue: () => null,
  },
  "email.default_provider": {
    key: "email.default_provider",
    label: "Default email provider",
    description: "Routes transactional email and seeds the provider for newly composed campaigns.",
    environmentName: "INLINE_CONFIG_EMAIL_DEFAULT_PROVIDER",
    allowedValues: emailProviders,
    defaultValue: "resend",
    legacyEnvironmentValue: legacyEmailProvider,
  },
}

// Deliberately empty in normal builds. A reviewed server-only incident override
// belongs here and outranks environment and database configuration.
const serverOverrides: Readonly<{
  readonly [K in ServerConfigKey]?: ServerConfigValue<K>
}> = Object.freeze({})

let cachedRows = new Map<ServerConfigKey, DbServerConfig>()
let lastRefreshAttemptAt = 0
let refreshInFlight: Promise<ReadonlyMap<ServerConfigKey, DbServerConfig>> | null = null

const isServerConfigKey = (value: string): value is ServerConfigKey =>
  SERVER_CONFIG_KEYS.includes(value as ServerConfigKey)

export const parseServerConfigValue = <K extends ServerConfigKey>(
  key: K,
  value: unknown,
): ServerConfigValue<K> | null => {
  if (typeof value !== "string") return null
  const normalized = value.trim().toLowerCase()
  return definitions[key].allowedValues.includes(normalized)
    ? normalized as ServerConfigValue<K>
    : null
}

const validLayerValue = <K extends ServerConfigKey>(
  key: K,
  layer: ServerConfigSource,
  value: unknown,
): ServerConfigValue<K> | null => {
  if (value === undefined || value === null) return null
  const parsed = parseServerConfigValue(key, value)
  if (parsed) return parsed
  const warningKey = `${key}:${layer}`
  if (!warnedInvalidLayers.has(warningKey)) {
    warnedInvalidLayers.add(warningKey)
    log.warn("Ignoring invalid server configuration value", { key, layer })
  }
  return null
}

export const resolveServerConfigValue = <K extends ServerConfigKey>(
  key: K,
  layers: ResolutionLayers,
): { readonly value: ServerConfigValue<K>; readonly source: ServerConfigSource } => {
  const candidates: readonly [ServerConfigSource, unknown][] = [
    ["server_override", layers.serverOverride],
    ["environment", layers.environmentOverride],
    ["database", layers.databaseValue],
    ["legacy_environment", layers.legacyEnvironmentValue],
  ]
  for (const [source, candidate] of candidates) {
    const value = validLayerValue(key, source, candidate)
    if (value) return { value, source }
  }
  return { value: definitions[key].defaultValue, source: "default" }
}

const refreshRows = async (
  force = false,
): Promise<ReadonlyMap<ServerConfigKey, DbServerConfig>> => {
  const now = Date.now()
  if (!force && now - lastRefreshAttemptAt < CACHE_TTL_MS) return cachedRows
  if (refreshInFlight) return refreshInFlight

  lastRefreshAttemptAt = now
  refreshInFlight = db
    .select()
    .from(serverConfig)
    .then((rows) => {
      const next = new Map<ServerConfigKey, DbServerConfig>()
      for (const row of rows) {
        if (isServerConfigKey(row.key)) next.set(row.key, row)
      }
      cachedRows = next
      return cachedRows
    })
    .catch((error) => {
      log.error("Failed to refresh server configuration; retaining the last snapshot", { error })
      return cachedRows
    })
    .finally(() => {
      refreshInFlight = null
    })
  return refreshInFlight
}

const resolveEntry = <K extends ServerConfigKey>(
  key: K,
  rows: ReadonlyMap<ServerConfigKey, DbServerConfig>,
): ResolvedServerConfig<K> => {
  const definition = definitions[key]
  const row = rows.get(key)
  const databaseValue = row ? parseServerConfigValue(key, row.value) : null
  const resolved = resolveServerConfigValue(key, {
    serverOverride: serverOverrides[key],
    environmentOverride: process.env[definition.environmentName],
    databaseValue: row?.value,
    legacyEnvironmentValue: definition.legacyEnvironmentValue(),
  })
  return {
    key,
    label: definition.label,
    description: definition.description,
    environmentName: definition.environmentName,
    allowedValues: definition.allowedValues,
    value: resolved.value,
    source: resolved.source,
    databaseValue,
    databaseVersion: row?.version ?? null,
    databaseUpdatedAt: row?.updatedAt.toISOString() ?? null,
    databaseUpdatedByUserId: row?.updatedByUserId ?? null,
  }
}

export const getServerConfig = async <K extends ServerConfigKey>(
  key: K,
): Promise<ResolvedServerConfig<K>> => resolveEntry(key, await refreshRows())

export const listServerConfig = async (): Promise<readonly ResolvedServerConfig[]> => {
  const rows = await refreshRows()
  return SERVER_CONFIG_KEYS.map((key) => resolveEntry(key, rows))
}

export type UpdateServerConfigResult<K extends ServerConfigKey = ServerConfigKey> =
  | { readonly updated: true; readonly setting: ResolvedServerConfig<K> }
  | { readonly updated: false; readonly currentVersion: number | null }

export const updateServerConfig = async <K extends ServerConfigKey>(input: {
  readonly key: K
  readonly value: ServerConfigValue<K>
  readonly expectedVersion: number | null
  readonly updatedByUserId: number
}): Promise<UpdateServerConfigResult<K>> => {
  const now = new Date()
  let updated: DbServerConfig | undefined
  const value = parseServerConfigValue(input.key, input.value)
  if (!value) throw new TypeError(`Invalid value for server configuration key ${input.key}`)

  if (input.expectedVersion === null) {
    updated = (
      await db
        .insert(serverConfig)
        .values({
          key: input.key,
          value,
          updatedByUserId: input.updatedByUserId,
          updatedAt: now,
        })
        .onConflictDoNothing({ target: serverConfig.key })
        .returning()
    )[0]
  } else {
    updated = (
      await db
        .update(serverConfig)
        .set({
          value,
          version: sql`${serverConfig.version} + 1`,
          updatedByUserId: input.updatedByUserId,
          updatedAt: now,
        })
        .where(and(
          eq(serverConfig.key, input.key),
          eq(serverConfig.version, input.expectedVersion),
        ))
        .returning()
    )[0]
  }

  if (!updated) {
    const current = (
      await db
        .select()
        .from(serverConfig)
        .where(eq(serverConfig.key, input.key))
        .limit(1)
    )[0]
    const nextRows = new Map(cachedRows)
    if (current) nextRows.set(input.key, current)
    else nextRows.delete(input.key)
    cachedRows = nextRows
    lastRefreshAttemptAt = Date.now()
    return { updated: false, currentVersion: current?.version ?? null }
  }

  cachedRows = new Map(cachedRows).set(input.key, updated)
  lastRefreshAttemptAt = Date.now()
  return { updated: true, setting: resolveEntry(input.key, cachedRows) }
}

export const resetServerConfigCacheForTests = (): void => {
  cachedRows = new Map()
  lastRefreshAttemptAt = 0
  refreshInFlight = null
  warnedInvalidLayers.clear()
}
