import { beforeEach, describe, expect, test } from "bun:test"
import { ConnectorProvider } from "@inline-chat/protocol/core"
import { and, eq, isNull, sql } from "drizzle-orm"
import { db } from "@in/server/db"
import { integrationOAuthStates, integrations, members, spaces, users } from "@in/server/db/schema"
import {
  disconnectConnector,
  listConnectors,
  prepareConnectorOAuth,
} from "@in/server/functions/connectors"
import {
  claimConnectorOAuthState,
  storeConnectorOAuthState,
} from "@in/server/modules/integrations/connectorOAuthState"
import { resolveConnectorCallbackScheme } from "@in/server/modules/integrations/connectorCallbackScheme"
import type { HandlerContext } from "@in/server/realtime/types"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { setupTestLifecycle, testUtils } from "../setup"

describe("connectors", () => {
  setupTestLifecycle()

  let currentUserId = 0
  let context: HandlerContext

  beforeEach(async () => {
    const currentUser = await testUtils.createUser("connectors-current@example.com")
    await db
      .update(users)
      .set({ firstName: "Current", lastName: "User" })
      .where(eq(users.id, currentUser.id))
    currentUserId = currentUser.id
    context = {
      userId: currentUserId,
      sessionId: 1,
      connectionId: "connectors-test",
      sendRaw: () => {},
      sendRpcReply: () => {},
    }
  })

  test("lists usable connections while collapsing legacy duplicate rows", async () => {
    const [space] = await db.insert(spaces).values({ name: "Design" }).returning()
    if (!space) throw new Error("space not created")
    await db.insert(members).values({
      userId: currentUserId,
      spaceId: space.id,
      role: "admin",
    })
    await db.insert(integrations).values([
      {
        userId: currentUserId,
        provider: "notion",
        date: new Date("2026-01-01T00:00:00Z"),
        accessTokenEncrypted: Buffer.from("older-encrypted"),
        accessTokenIv: Buffer.from("older-iv"),
        accessTokenTag: Buffer.from("older-tag"),
      },
      {
        userId: currentUserId,
        provider: "notion",
        date: new Date("2026-02-01T00:00:00Z"),
        accessTokenEncrypted: Buffer.from("newer-encrypted"),
        accessTokenIv: Buffer.from("newer-iv"),
        accessTokenTag: Buffer.from("newer-tag"),
      },
      {
        userId: currentUserId,
        spaceId: space.id,
        provider: "linear",
        date: new Date("2026-03-01T00:00:00Z"),
        accessTokenEncrypted: Buffer.from("linear-encrypted"),
        accessTokenIv: Buffer.from("linear-iv"),
        accessTokenTag: Buffer.from("linear-tag"),
      },
    ])

    const result = await listConnectors(context)

    expect(result.scopes).toHaveLength(2)
    expect(result.providers.find((item) => item.provider === ConnectorProvider.NOTION))
      .toMatchObject({ supportsUserScope: true, supportsSpaceScope: true })
    expect(result.providers.find((item) => item.provider === ConnectorProvider.LINEAR))
      .toMatchObject({ supportsUserScope: false, supportsSpaceScope: true })
    expect(result.scopes[0]).toMatchObject({
      scope: {
        type: {
          oneofKind: "user",
          user: { user: { id: BigInt(currentUserId) } },
        },
      },
      canManage: true,
    })
    expect(result.scopes[1]).toMatchObject({
      scope: {
        type: {
          oneofKind: "space",
          space: { space: { id: BigInt(space.id), name: "Design" } },
        },
      },
      canManage: true,
    })
    expect(result.connections).toHaveLength(2)
    expect(result.connections.find((item) => item.provider === ConnectorProvider.NOTION)?.connectedAt)
      .toBe(BigInt(Date.parse("2026-02-01T00:00:00Z") / 1_000))
    expect(result.connections.find((item) => item.provider === ConnectorProvider.NOTION)?.needsConfiguration)
      .toBe(false)
    const linearConnection = result.connections.find(
      (item) => item.provider === ConnectorProvider.LINEAR,
    )
    expect(linearConnection?.needsConfiguration).toBe(true)
    expect(linearConnection?.connectedBy)
      .toMatchObject({ firstName: "Current", lastName: "User", min: true })
  })

  test("does not report a tokenless integration as connected", async () => {
    await db.insert(integrations).values({
      userId: currentUserId,
      provider: "notion",
    })

    const result = await listConnectors(context)

    expect(result.connections).toHaveLength(0)
  })

  test("keeps the default connection time as an absolute instant outside UTC", async () => {
    const beforeInsert = Date.now()
    await db.transaction(async (tx) => {
      await tx.execute(sql`set local time zone 'Asia/Tehran'`)
      await tx.insert(integrations).values({
        userId: currentUserId,
        provider: "notion",
        accessTokenEncrypted: Buffer.from("encrypted"),
        accessTokenIv: Buffer.from("iv"),
        accessTokenTag: Buffer.from("tag"),
      })
    })
    const afterInsert = Date.now()

    const result = await listConnectors(context)
    const connectedAt = result.connections.find(
      (item) => item.provider === ConnectorProvider.NOTION,
    )?.connectedAt

    expect(connectedAt).toBeDefined()
    expect(Number(connectedAt) * 1_000).toBeGreaterThanOrEqual(beforeInsert - 1_000)
    expect(Number(connectedAt) * 1_000).toBeLessThanOrEqual(afterInsert + 1_000)
  })

  test("preserves legacy wall-clock instants when converting outside UTC", async () => {
    for (const timeZone of ["UTC", "Asia/Tehran"] as const) {
      await db.transaction(async (tx) => {
        await tx.execute(sql.raw(`set local time zone '${timeZone}'`))
        await tx.execute(sql`
          create temporary table connector_time_migration_check (
            date timestamp(3) without time zone default now()
          ) on commit drop
        `)
        const beforeInsert = Date.now()
        await tx.execute(sql`insert into connector_time_migration_check default values`)
        await tx.execute(sql`
          alter table connector_time_migration_check
          alter column date type timestamp(3) with time zone
          using date at time zone current_setting('TimeZone')
        `)
        const [stored] = await tx.execute<{ epoch: number }>(sql`
          select extract(epoch from date)::double precision as epoch
          from connector_time_migration_check
        `)
        const afterInsert = Date.now()
        if (!stored) throw new Error("migrated timestamp not found")

        expect(stored.epoch * 1_000).toBeGreaterThanOrEqual(beforeInsert - 1_000)
        expect(stored.epoch * 1_000).toBeLessThanOrEqual(afterInsert + 1_000)
      })
    }
  })

  test("exposes a public-space connection to admins only for cleanup", async () => {
    const [space] = await db.insert(spaces).values({
      name: "Public Community",
      isPublic: true,
    }).returning()
    if (!space) throw new Error("space not created")
    await db.insert(members).values({
      userId: currentUserId,
      spaceId: space.id,
      role: "admin",
    })
    await db.insert(integrations).values({
      userId: currentUserId,
      spaceId: space.id,
      provider: "notion",
      accessTokenEncrypted: Buffer.from("encrypted"),
      accessTokenIv: Buffer.from("iv"),
      accessTokenTag: Buffer.from("tag"),
    })

    const result = await listConnectors(context)

    expect(result.scopes).toHaveLength(2)
    expect(result.scopes[1]).toMatchObject({
      canManage: true,
      allowsConnections: false,
    })
    expect(result.connections).toHaveLength(1)

    await expect(prepareConnectorOAuth({
      provider: ConnectorProvider.NOTION,
      callbackScheme: "inline-dev",
      scope: {
        type: {
          oneofKind: "space",
          space: { spaceId: BigInt(space.id) },
        },
      },
    }, context)).rejects.toMatchObject({
      code: RealtimeRpcError.Code.BAD_REQUEST,
    })

    const member = await testUtils.createUser("public-connector-member@example.com")
    await db.insert(members).values({
      userId: member.id,
      spaceId: space.id,
      role: "member",
    })
    const memberResult = await listConnectors({ ...context, userId: member.id })
    expect(memberResult.scopes[1]).toMatchObject({
      canManage: false,
      allowsConnections: false,
    })
    expect(memberResult.connections).toHaveLength(0)
  })

  test("disconnects every legacy row for the selected personal scope", async () => {
    const rows = await db.insert(integrations).values([
      {
        userId: currentUserId,
        provider: "notion",
        accessTokenEncrypted: Buffer.from("first"),
        accessTokenIv: Buffer.from("first-iv"),
        accessTokenTag: Buffer.from("first-tag"),
      },
      {
        userId: currentUserId,
        provider: "notion",
        accessTokenEncrypted: Buffer.from("second"),
        accessTokenIv: Buffer.from("second-iv"),
        accessTokenTag: Buffer.from("second-tag"),
      },
    ])
      .returning({ id: integrations.id })
    const revokedIDs: number[] = []

    await disconnectConnector({
      provider: ConnectorProvider.NOTION,
      scope: {
        type: {
          oneofKind: "user",
          user: { userId: BigInt(currentUserId) },
        },
      },
    }, context, {
      async revokeConnection(_provider, connection) {
        revokedIDs.push(connection.id)
        return { ok: true }
      },
    })

    const remaining = await db
      .select({ id: integrations.id })
      .from(integrations)
      .where(and(
        eq(integrations.userId, currentUserId),
        isNull(integrations.spaceId),
        eq(integrations.provider, "notion"),
      ))
    expect(remaining).toHaveLength(0)
    expect(revokedIDs.sort()).toEqual(rows.map((row) => row.id).sort())
  })

  test("requires an admin to disconnect a space connector", async () => {
    const [space] = await db.insert(spaces).values({ name: "Member Space" }).returning()
    if (!space) throw new Error("space not created")
    await db.insert(members).values({
      userId: currentUserId,
      spaceId: space.id,
      role: "member",
    })

    try {
      await disconnectConnector({
        provider: ConnectorProvider.NOTION,
        scope: {
          type: {
            oneofKind: "space",
            space: { spaceId: BigInt(space.id) },
          },
        },
      }, context)
      throw new Error("expected disconnect to fail")
    } catch (error) {
      expect(RealtimeRpcError.is(
        error,
        RealtimeRpcError.Code.SPACE_ADMIN_REQUIRED,
      )).toBe(true)
    }
  })

  test("stores only a digest and claims OAuth state once", async () => {
    await storeConnectorOAuthState({
      state: "raw-secret-state",
      provider: "notion",
      callbackScheme: "inline-dev",
      userId: currentUserId,
      spaceId: null,
    })

    const [stored] = await db.select().from(integrationOAuthStates)
    expect(stored?.stateHash).not.toContain("raw-secret-state")
    expect(stored?.stateHash).toHaveLength(64)

    expect(await claimConnectorOAuthState("raw-secret-state", "linear")).toBeNull()
    expect(await claimConnectorOAuthState("raw-secret-state", "notion")).toEqual({
      userId: currentUserId,
      spaceId: null,
      callbackScheme: "inline-dev",
    })
    expect(await claimConnectorOAuthState("raw-secret-state", "notion")).toBeNull()
  })

  test("keeps concurrent OAuth states independent across app variants", async () => {
    await storeConnectorOAuthState({
      state: "debug-state",
      provider: "notion",
      callbackScheme: "inline-debug",
      userId: currentUserId,
      spaceId: null,
    })
    await storeConnectorOAuthState({
      state: "dev-state",
      provider: "notion",
      callbackScheme: "inline-dev",
      userId: currentUserId,
      spaceId: null,
    })

    expect(await claimConnectorOAuthState("debug-state", "notion")).toEqual({
      userId: currentUserId,
      spaceId: null,
      callbackScheme: "inline-debug",
    })
    expect(await claimConnectorOAuthState("dev-state", "notion")).toEqual({
      userId: currentUserId,
      spaceId: null,
      callbackScheme: "inline-dev",
    })
  })

  test("allows known app callback schemes without accepting arbitrary redirects", () => {
    expect(resolveConnectorCallbackScheme("")).toBe("in")
    expect(resolveConnectorCallbackScheme("IN")).toBe("in")
    expect(resolveConnectorCallbackScheme("inline-debug-2")).toBe("inline-debug-2")
    expect(resolveConnectorCallbackScheme("inline-dev")).toBe("inline-dev")
    expect(resolveConnectorCallbackScheme("https")).toBeNull()
    expect(resolveConnectorCallbackScheme("in://attacker.example")).toBeNull()
  })
})
