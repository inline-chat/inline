import profile from "../deploy/ha-node-profile.json"

type RecordValue = Record<string, unknown>
export type NodeName = keyof typeof profile.nodes
export type ReleaseBinding = {
  arm64Image: string | null
  sourceRevision: string | null
  rollbackArm64Image: string | null
  rollbackSourceRevision: string | null
}

const imagePattern = /^[a-z0-9][a-z0-9.:-]*(?:\/[a-z0-9][a-z0-9._-]*)+@sha256:[a-f0-9]{64}$/
const sourcePattern = /^[a-f0-9]{40}$/
const sections = {
  image: ["reference", "sourceRevision", "architecture"],
  runtime: ["running", "readyzStatus", "role", "distributedMode", "queryPoolMax", "shutdownTimeoutMs", "ingressHost", "ingressMode", "directIpSource", "nativeProtocolEnabled", "clusterServicesEnabled", "migrationOnBoot"],
  container: ["cpuLimit", "memoryBytes", "memoryPlusSwapBytes", "restartPolicy", "stopGraceSeconds", "publishedHostPorts", "privateBackendNetwork", "fixedContainerName", "logMaxSize", "logMaxFiles"],
  health: ["path", "intervalSeconds", "timeoutSeconds", "retries", "startPeriodSeconds"],
  tls: ["host", "verified", "expiresAt"],
  isolation: ["productionCredentials", "publicRouting", "syntheticDatabase"],
} as const

const isRecord = (value: unknown): value is RecordValue =>
  typeof value === "object" && value !== null && !Array.isArray(value)

// Consume deliberately sanitized metadata, never docker inspect, environment
// dumps, raw Coolify responses, logs or resolved Compose output. Unknown keys
// are rejected without echoing their names or values.
export const parseHostMetadata = (input: unknown): RecordValue => {
  if (!isRecord(input) || Object.keys(input).some((key) => !Object.hasOwn(sections, key))) {
    throw new Error("Expected sanitized host metadata sections.")
  }
  for (const [key, allowed] of Object.entries(sections)) {
    const value = input[key]
    if (value === undefined) continue
    if (!isRecord(value) || Object.keys(value).some((field) => !new Set<string>(allowed).has(field))) {
      throw new Error("Unexpected host metadata fields; provide an explicit safe projection.")
    }
    if (Object.values(value).some((field) =>
      field !== null && typeof field === "object" &&
      (!Array.isArray(field) || field.length !== 0))) {
      throw new Error("Host metadata values must be scalar or an empty ports list.")
    }
  }
  return input
}

export const qualifyHaHost = (
  node: NodeName,
  metadata: unknown,
  release: ReleaseBinding = profile.release,
  now = Date.now(),
) => {
  const input = parseHostMetadata(metadata)
  const missing: string[] = []
  const failed: string[] = []
  const matched: string[] = []
  const check = (section: string, field: string, expected: unknown) => {
    const values = input[section]
    const actual = isRecord(values) ? values[field] : undefined
    const key = `${section}.${field}`
    if (actual === undefined || actual === null) missing.push(key)
    else if (Array.isArray(expected) ? Array.isArray(actual) && actual.length === 0 : actual === expected) matched.push(key)
    else failed.push(key)
  }
  for (const [key, pattern] of [
    ["arm64Image", imagePattern], ["sourceRevision", sourcePattern],
    ["rollbackArm64Image", imagePattern], ["rollbackSourceRevision", sourcePattern],
  ] as const) {
    const value = release[key]
    if (value === null) missing.push(`release.${key}`)
    else if (!pattern.test(value)) failed.push(`release.${key}`)
  }
  if (release.arm64Image !== null) check("image", "reference", release.arm64Image)
  if (release.sourceRevision !== null) check("image", "sourceRevision", release.sourceRevision)
  check("image", "architecture", profile.common.architecture)
  const expectedRuntime = {
    running: true,
    readyzStatus: profile.common.health.expectedStatus,
    role: profile.common.environment.INLINE_PROCESS_ROLE,
    distributedMode: true,
    queryPoolMax: Number(profile.common.environment.INLINE_DATABASE_QUERY_POOL_MAX),
    shutdownTimeoutMs: Number(profile.common.environment.SHUTDOWN_TIMEOUT_MS),
    ingressHost: profile.common.environment.INLINE_INGRESS_HOST,
    ingressMode: profile.common.environment.INLINE_INGRESS_MODE,
    directIpSource: profile.common.environment.INLINE_INGRESS_DIRECT_IP_SOURCE,
    nativeProtocolEnabled: profile.common.nativeProtocolEnabled,
    clusterServicesEnabled: profile.common.clusterServicesEnabled,
    migrationOnBoot: profile.common.migrationOnBoot,
  }
  for (const [key, expected] of Object.entries(expectedRuntime)) check("runtime", key, expected)
  const expectedContainer = {
    cpuLimit: profile.nodes[node].cpuLimit,
    memoryBytes: profile.nodes[node].memoryBytes,
    memoryPlusSwapBytes: profile.nodes[node].memoryPlusSwapBytes,
    restartPolicy: profile.common.restartPolicy,
    stopGraceSeconds: profile.common.stopGraceSeconds,
    publishedHostPorts: profile.common.publishedHostPorts,
    privateBackendNetwork: profile.common.privateBackendNetwork,
    fixedContainerName: profile.common.fixedContainerName,
    logMaxSize: profile.common.logMaxSize,
    logMaxFiles: profile.common.logMaxFiles,
  }
  for (const [key, expected] of Object.entries(expectedContainer)) check("container", key, expected)
  for (const [key, expected] of Object.entries(profile.common.health)) {
    if (key !== "expectedStatus") check("health", key, expected)
  }
  check("tls", "host", profile.common.canonicalTlsHost)
  check("tls", "verified", true)
  const tls = input["tls"]
  const expiry = isRecord(tls) ? tls["expiresAt"] : undefined
  if (expiry === undefined || expiry === null) missing.push("tls.expiresAt")
  else if (typeof expiry !== "string" || !Number.isFinite(Date.parse(expiry)) || Date.parse(expiry) <= now) failed.push("tls.expiresAt")
  else matched.push("tls.expiresAt")
  const isolation = input["isolation"]
  const fixtureOnly = isRecord(isolation) && isolation["syntheticDatabase"] === true &&
    isolation["productionCredentials"] === false && isolation["publicRouting"] === false
  return {
    node,
    state: failed.length ? "mismatch" : missing.length ? "incomplete" : "matches-runtime-profile",
    scope: "supplied sanitized metadata only",
    fixtureOnly,
    productionQualified: false,
    matched,
    missing,
    failed,
    remaining: ["Live authenticated V2/V3 and catch-up", "Cross-node delivery and worker ownership", "Real proxy header and TLS renewal boundary", "Measured drain, rollback and routing transition"],
  }
}

const main = async () => {
  const args = process.argv.slice(2)
  if (args.length !== 4 || args[0] !== "--node" || !["nbg", "finland"].includes(args[1] ?? "") || args[2] !== "--metadata") {
    throw new Error("Usage: bun --no-env-file server/scripts/qualify-ha-host.ts --node nbg|finland --metadata SANITIZED_JSON")
  }
  if (!args[3]?.endsWith(".json")) throw new Error("Expected a sanitized JSON metadata file.")
  const file = Bun.file(args[3])
  if (file.size > 65_536) throw new Error("Sanitized metadata exceeds the 64 KiB bound.")
  const result = qualifyHaHost(args[1] as NodeName, await file.json())
  console.log(JSON.stringify(result, null, 2))
  if (result.state !== "matches-runtime-profile") process.exitCode = 1
}

if (import.meta.main) {
  main().catch(() => {
    // Parser/provider inputs can contain secrets; do not echo them or errors.
    console.error("HA host qualification failed. Supply a selected node and bounded sanitized metadata; no input values were emitted.")
    process.exitCode = 1
  })
}
