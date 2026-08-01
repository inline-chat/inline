import postgres from "postgres"

export type LiveKitProvider = "cloud" | "self_hosted"

type Environment = Readonly<Record<string, string | undefined>>

export type LiveKitCutoverEnvironmentState = {
  expectedProvider: LiveKitProvider
  selectedProvider: LiveKitProvider | "invalid"
  selectorExplicit: boolean
  selectorMatchesExpected: boolean
  cloudTripletComplete: boolean
  selfHostedTripletComplete: boolean
  legacyTripletComplete: boolean
  legacyFallbackActive: boolean
}

export type LiveKitCutoverDatabaseState = {
  migrationApplied: boolean
  totalEffects: number | null
  legacyUnboundEffects: number | null
  unknownOwnerEffects: number | null
  claimedEffects: number | null
  maximumAttempts: number | null
  activeRooms: number
}

export type LiveKitCutoverPreflight = {
  ready: boolean
  failures: string[]
  environment: LiveKitCutoverEnvironmentState
  database: LiveKitCutoverDatabaseState | null
}

const PROVIDER_VARIABLES: Record<LiveKitProvider, readonly string[]> = {
  cloud: ["LIVEKIT_CLOUD_URL", "LIVEKIT_CLOUD_API_KEY", "LIVEKIT_CLOUD_API_SECRET"],
  self_hosted: [
    "LIVEKIT_SELF_HOSTED_URL",
    "LIVEKIT_SELF_HOSTED_API_KEY",
    "LIVEKIT_SELF_HOSTED_API_SECRET",
  ],
}

const LEGACY_VARIABLES = ["LIVEKIT_URL", "LIVEKIT_API_KEY", "LIVEKIT_API_SECRET"] as const

export function inspectLiveKitCutoverEnvironment(
  environment: Environment,
  expectedProvider: LiveKitProvider,
): LiveKitCutoverEnvironmentState {
  const selector = environment["LIVEKIT_PROVIDER"]?.trim().toLowerCase() || "self_hosted"
  const selectorExplicit = !!environment["LIVEKIT_PROVIDER"]?.trim()
  const selectedProvider = isLiveKitProvider(selector) ? selector : "invalid"
  const cloudTripletComplete = completeTriplet(environment, PROVIDER_VARIABLES.cloud)
  const selfHostedTripletComplete = completeTriplet(environment, PROVIDER_VARIABLES.self_hosted)
  const legacyTripletComplete = completeTriplet(environment, LEGACY_VARIABLES)
  const selectedTripletComplete = selectedProvider === "cloud"
    ? cloudTripletComplete
    : selectedProvider === "self_hosted"
      ? selfHostedTripletComplete
      : false

  return {
    expectedProvider,
    selectedProvider,
    selectorExplicit,
    selectorMatchesExpected: selectedProvider === expectedProvider,
    cloudTripletComplete,
    selfHostedTripletComplete,
    legacyTripletComplete,
    legacyFallbackActive: selectedProvider !== "invalid" && !selectedTripletComplete && legacyTripletComplete,
  }
}

export function evaluateLiveKitCutoverPreflight(
  environment: LiveKitCutoverEnvironmentState,
  database: LiveKitCutoverDatabaseState | null,
): LiveKitCutoverPreflight {
  const failures: string[] = []
  if (!environment.selectorExplicit) failures.push("provider_selector_not_explicit")
  if (!environment.selectorMatchesExpected) failures.push("provider_selector_mismatch")
  if (!environment.cloudTripletComplete) failures.push("cloud_triplet_incomplete")
  if (!environment.selfHostedTripletComplete) failures.push("self_hosted_triplet_incomplete")
  if (environment.legacyFallbackActive) failures.push("legacy_fallback_active")

  if (!database) {
    failures.push("database_probe_failed")
  } else {
    if (!database.migrationApplied) failures.push("migration_0100_missing")
    if (database.totalEffects !== null && database.totalEffects !== 0) failures.push("provider_effects_not_empty")
    if (database.legacyUnboundEffects !== null && database.legacyUnboundEffects !== 0) {
      failures.push("legacy_provider_effects_present")
    }
    if (database.unknownOwnerEffects !== null && database.unknownOwnerEffects !== 0) {
      failures.push("unconfigured_provider_effects_present")
    }
    if (database.claimedEffects !== null && database.claimedEffects !== 0) {
      failures.push("claimed_provider_effects_present")
    }
    if (database.activeRooms !== 0) failures.push("active_grid_rooms_not_drained")
  }

  return {
    ready: failures.length === 0,
    failures,
    environment,
    database,
  }
}

export async function inspectLiveKitCutoverDatabase(
  databaseUrl: string | undefined,
): Promise<LiveKitCutoverDatabaseState> {
  if (!databaseUrl?.trim()) throw new Error("DATABASE_URL is not configured")

  const client = postgres(databaseUrl, { max: 1 })
  try {
    return await client.begin("read only", async (sql) => {
      const [column] = await sql<{ present: boolean }[]>`
        select exists (
          select 1
          from information_schema.columns
          where table_schema = current_schema()
            and table_name = 'grid_provider_effects'
            and column_name = 'provider_target'
        ) as present
      `
      const [rooms] = await sql<{ active_rooms: number }[]>`
        select count(*)::integer as active_rooms
        from grid_rooms
        where connection_started_at is not null
      `

      if (!column?.present) {
        return {
          migrationApplied: false,
          totalEffects: null,
          legacyUnboundEffects: null,
          unknownOwnerEffects: null,
          claimedEffects: null,
          maximumAttempts: null,
          activeRooms: rooms?.active_rooms ?? 0,
        }
      }

      const [effects] = await sql<{
        total_effects: number
        legacy_unbound_effects: number
        unknown_owner_effects: number
        claimed_effects: number
        maximum_attempts: number
      }[]>`
        select
          count(*)::integer as total_effects,
          count(*) filter (where provider_target is null)::integer as legacy_unbound_effects,
          count(*) filter (where provider_target = 'unconfigured')::integer as unknown_owner_effects,
          count(*) filter (where claim_token is not null)::integer as claimed_effects,
          coalesce(max(attempts), 0)::integer as maximum_attempts
        from grid_provider_effects
      `

      return {
        migrationApplied: true,
        totalEffects: effects?.total_effects ?? 0,
        legacyUnboundEffects: effects?.legacy_unbound_effects ?? 0,
        unknownOwnerEffects: effects?.unknown_owner_effects ?? 0,
        claimedEffects: effects?.claimed_effects ?? 0,
        maximumAttempts: effects?.maximum_attempts ?? 0,
        activeRooms: rooms?.active_rooms ?? 0,
      }
    })
  } finally {
    await client.end({ timeout: 5 })
  }
}

function completeTriplet(environment: Environment, variables: readonly string[]): boolean {
  return variables.every((variable) => !!environment[variable]?.trim())
}

function isLiveKitProvider(value: string): value is LiveKitProvider {
  return value === "cloud" || value === "self_hosted"
}

function expectedProviderFromArguments(arguments_: string[]): LiveKitProvider | undefined {
  const inline = arguments_.find((argument) => argument.startsWith("--expect-provider="))
  const inlineValue = inline?.slice("--expect-provider=".length)
  const separateIndex = arguments_.indexOf("--expect-provider")
  const value = inlineValue ?? (separateIndex >= 0 ? arguments_[separateIndex + 1] : undefined)
  return value && isLiveKitProvider(value) ? value : undefined
}

async function main(): Promise<number> {
  const expectedProvider = expectedProviderFromArguments(process.argv.slice(2))
  if (!expectedProvider) {
    console.error("Usage: bun run livekit:cutover-preflight --expect-provider cloud|self_hosted")
    return 2
  }

  const environment = inspectLiveKitCutoverEnvironment(process.env, expectedProvider)
  let database: LiveKitCutoverDatabaseState | null = null
  try {
    database = await inspectLiveKitCutoverDatabase(process.env["DATABASE_URL"])
  } catch {
    // Keep connection details and credentials out of preflight output.
  }
  const result = evaluateLiveKitCutoverPreflight(environment, database)
  console.log(JSON.stringify(result, null, 2))
  return result.ready ? 0 : 1
}

if (import.meta.main) {
  process.exit(await main())
}
