import { expect, test } from "bun:test"
import { parseHostMetadata, qualifyHaHost, type ReleaseBinding } from "./qualify-ha-host"

const release: ReleaseBinding = {
  arm64Image: `registry.example/inline-api@sha256:${"a".repeat(64)}`,
  sourceRevision: "b".repeat(40),
  rollbackArm64Image: `registry.example/inline-api@sha256:${"c".repeat(64)}`,
  rollbackSourceRevision: "d".repeat(40),
}

const metadata = () => ({
  image: { reference: release.arm64Image, sourceRevision: release.sourceRevision, architecture: "arm64" },
  runtime: {
    running: true, readyzStatus: 200, role: "all", distributedMode: true,
    queryPoolMax: 3, shutdownTimeoutMs: 40_000, ingressHost: "api.inline.chat",
    ingressMode: "cloudflare-optional", directIpSource: "x-real-ip",
    nativeProtocolEnabled: true, clusterServicesEnabled: true, migrationOnBoot: false,
  },
  container: {
    cpuLimit: 2, memoryBytes: 1_610_612_736, memoryPlusSwapBytes: 1_610_612_736,
    restartPolicy: "unless-stopped", stopGraceSeconds: 45, publishedHostPorts: [],
    privateBackendNetwork: true, fixedContainerName: false, logMaxSize: "10m", logMaxFiles: 3,
  },
  health: { path: "/readyz", intervalSeconds: 5, timeoutSeconds: 3, retries: 3, startPeriodSeconds: 15 },
  tls: { host: "api.inline.chat", verified: true, expiresAt: "2030-01-01T00:00:00Z" },
  isolation: { productionCredentials: false, publicRouting: false, syntheticDatabase: true },
})

test("matching fixture metadata never claims production acceptance", () => {
  const result = qualifyHaHost("nbg", metadata(), release, 0)
  expect(result).toMatchObject({ state: "matches-runtime-profile", fixtureOnly: true, productionQualified: false, missing: [], failed: [] })
  expect(result.remaining).toContain("Cross-node delivery and worker ownership")
})

test("readiness from the existing reduced artifact harness does not qualify full API behavior", () => {
  const input = metadata()
  Object.assign(input.runtime, { role: "api", nativeProtocolEnabled: false, clusterServicesEnabled: false })
  const result = qualifyHaHost("nbg", input, release, 0)
  expect(result.state).toBe("mismatch")
  expect(result.failed).toEqual(["runtime.role", "runtime.nativeProtocolEnabled", "runtime.clusterServicesEnabled"])
})

test("retained old source or a mutable image cannot satisfy release identity", () => {
  const input = metadata()
  input.image.sourceRevision = "e".repeat(40)
  expect(qualifyHaHost("nbg", input, release, 0).failed).toContain("image.sourceRevision")
  expect(qualifyHaHost("nbg", metadata(), { ...release, arm64Image: "registry.example/inline-api:latest" }, 0).failed)
    .toContain("release.arm64Image")
})

test("unbound release placeholders and unknown observations stay incomplete", () => {
  const result = qualifyHaHost("finland", {})
  expect(result.state).toBe("incomplete")
  expect(result.missing).toContain("release.arm64Image")
  expect(result.missing).toContain("runtime.role")
  expect(result.productionQualified).toBe(false)
})

test("Finland caps, supervisor drain and certificate expiration are checked", () => {
  const input = metadata()
  input.container.logMaxSize = "2m"
  input.container.logMaxFiles = 2
  input.container.stopGraceSeconds = 30
  input.tls.expiresAt = "2026-10-15T00:00:00Z"
  const result = qualifyHaHost("finland", input, release, Date.parse("2026-10-15T01:00:00Z"))
  expect(result.failed).toEqual(["container.memoryBytes", "container.memoryPlusSwapBytes", "container.stopGraceSeconds", "tls.expiresAt"])
})

test("raw provider or environment payloads fail closed without echoing secrets", () => {
  for (const input of [
    { Config: { Env: ["SECRET=synthetic-credential"] } },
    { runtime: { role: "all", DATABASE_URL: "postgres://synthetic-credential" } },
    { constructor: "synthetic-credential" },
    { container: { publishedHostPorts: [8000] } },
  ]) {
    let output = ""
    try { output = JSON.stringify(parseHostMetadata(input)) }
    catch (cause) { output = cause instanceof Error ? cause.message : "rejected" }
    expect(output).not.toContain("synthetic-credential")
    expect(output).not.toContain("DATABASE_URL")
    expect(output).not.toContain("8000")
  }
})
