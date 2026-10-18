/**
 * Server half of the opt-in legacy V3 upgrade end-to-end check (scripts/e2e/legacy-v3-upgrade.sh).
 * Operates only on a local database whose name starts with `inline_e2e`.
 */
import { readFileSync, writeFileSync } from "node:fs"
import { eq } from "drizzle-orm"
import postgres from "postgres"
import { closeDb, db, schema } from "@in/server/db"
import { SessionsModel } from "@in/server/db/models/sessions"
import { inlineProtocolAuthKeys, sessions } from "@in/server/db/schema"
import { getServerConfig, updateServerConfig } from "@in/server/modules/serverConfig"
import { generateToken, hashToken } from "@in/server/utils/auth"

type Fixture = { userId: number; sessionId: number; token: string }

const databaseUrl = (): URL => {
  const raw = process.env["DATABASE_URL"]
  if (!raw) throw new Error("DATABASE_URL is required")
  const url = new URL(raw)
  if (!["localhost", "127.0.0.1"].includes(url.hostname) || !url.pathname.slice(1).startsWith("inline_e2e")) {
    throw new Error("Refusing to run outside a local inline_e2e* database")
  }
  return url
}

const readFixture = (path: string): Fixture => JSON.parse(readFileSync(path, "utf8")) as Fixture

async function createDatabase(): Promise<void> {
  const url = databaseUrl()
  const name = url.pathname.slice(1)
  const maintenance = new URL(url)
  maintenance.pathname = "/postgres"
  const admin = postgres(maintenance.toString(), { max: 1 })
  try {
    await admin.unsafe(`drop database if exists "${name}"`)
    await admin.unsafe(`create database "${name}"`)
  } finally {
    await admin.end()
  }
  console.log(JSON.stringify({ created: name }))
}

async function seed(path: string): Promise<void> {
  databaseUrl()
  const [user] = await db.insert(schema.users).values({ email: `legacy-v3-e2e-${Date.now()}@example.com` }).returning()
  if (!user) throw new Error("User insert failed")
  const { token, tokenHash } = await generateToken(user.id)
  const session = await SessionsModel.create({
    userId: user.id, tokenHash, personalData: { deviceName: "legacy v3 e2e" }, clientType: "macos",
  })
  const fixture: Fixture = { userId: user.id, sessionId: session.id, token }
  writeFileSync(path, JSON.stringify(fixture))
  console.log(JSON.stringify({ userId: user.id, sessionId: session.id }))
}

async function setTransport(value: string, path: string): Promise<void> {
  databaseUrl()
  if (value !== "v3" && value !== "v2") throw new Error("transport must be v3 or v2")
  const current = await getServerConfig("realtime.upgraded_session_transport")
  const result = await updateServerConfig({
    key: "realtime.upgraded_session_transport", value, expectedVersion: current.databaseVersion,
    updatedByUserId: readFixture(path).userId,
  })
  console.log(JSON.stringify({ updated: result.updated, value }))
}

async function setUpgradeMode(value: string, path: string): Promise<void> {
  databaseUrl()
  if (value !== "native" && value !== "disabled") throw new Error("upgrade mode must be native or disabled")
  const current = await getServerConfig("auth.session_upgrade_mode")
  const result = await updateServerConfig({
    key: "auth.session_upgrade_mode", value, expectedVersion: current.databaseVersion,
    updatedByUserId: readFixture(path).userId,
  })
  console.log(JSON.stringify({ updated: result.updated, value }))
}

async function inspect(path: string): Promise<void> {
  databaseUrl()
  const fixture = readFixture(path)
  const userSessions = await db.select().from(sessions).where(eq(sessions.userId, fixture.userId))
  const keys = await db.select().from(inlineProtocolAuthKeys).where(eq(inlineProtocolAuthKeys.userId, fixture.userId))
  const original = userSessions.find((session) => session.id === fixture.sessionId)
  console.log(JSON.stringify({
    sessions: userSessions.length,
    originalSessionKept: Boolean(original && !original.revoked),
    bearerUnchanged: original?.tokenHash === hashToken(fixture.token),
    boundKeys: keys.length,
    keysOnOriginalSession: keys.filter((key) => key.accountSessionId === fixture.sessionId && !key.revokedAt).length,
  }))
}

async function main(): Promise<number> {
  const [command, first, second] = process.argv.slice(2)
  try {
    switch (command) {
      case "create-db": await createDatabase(); break
      case "seed": await seed(first ?? "fixture.json"); break
      case "transport": await setTransport(first ?? "", second ?? "fixture.json"); break
      case "upgrade-mode": await setUpgradeMode(first ?? "", second ?? "fixture.json"); break
      case "inspect": await inspect(first ?? "fixture.json"); break
      default:
        console.error("Usage: legacy-v3-upgrade.ts create-db | seed <fixture> | transport <v3|v2> <fixture> | upgrade-mode <native|disabled> <fixture> | inspect <fixture>")
        return 2
    }
    return 0
  } finally {
    if (command !== "create-db") await closeDb()
  }
}

if (import.meta.main) process.exitCode = await main()
