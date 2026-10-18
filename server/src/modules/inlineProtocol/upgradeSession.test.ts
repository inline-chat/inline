import { afterEach, beforeEach, describe, expect, spyOn, test } from "bun:test"
import { eq, sql } from "drizzle-orm"
import { constants, generateKeyPairSync, privateDecrypt, randomBytes } from "node:crypto"
import { gunzipSync } from "node:zlib"
import {
  AuthUpgradeDeclined_Reason,
  Method,
  RealtimeV3Request,
  RealtimeV3Response,
  RpcError_Code,
  type AuthUpgradeSessionRequest,
} from "@inline-chat/protocol/core"
import {
  authKeyId, createTemporaryKeyBindingProof, decodeInlineApplicationObject, decodeRpcResult, decryptRecord,
  encodeBindTempAuthKey, encodeInlineInvoke,
  encryptRecord, InlineProtocolServerSession, makeRsaPublicKey, MessageIdGenerator,
  readInt64LE, ServiceConstructor, serviceConstructor,
} from "@inline-chat/protocol/secure"
import { db, schema } from "@in/server/db"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { InlineProtocolReplayRepository, PermanentAuthorizationKeyRepository } from "@in/server/db/models/inlineProtocol"
import { getUserIdFromToken } from "@in/server/modules/auth/sessionAuthentication"
import { handleRpcCall } from "@in/server/realtime/handlers/_rpc"
import { resetServerConfigCacheForTests } from "@in/server/modules/serverConfig"
import { lockGridMutations } from "@in/server/modules/grid/roomLifecycle"
import { revokeSessionInTransaction } from "@in/server/modules/sessions/revokeSession"
import { makeInlineProtocolApplicationDispatcher, type InlineProtocolApplicationContext } from "./application"
import { InlineProtocolAuthOperations } from "./auth"
import { InlineProtocolAuthorizationKeys } from "./authorizationKeys"
import { makeAuthorizationKeyCipher } from "./keyCipher"
import { InlineProtocolOperations } from "./operations"
import { makeInlineProtocolReplayRepository } from "./replay"
import { TemporaryAuthorizationKeyStore } from "./temporaryKeys"
import { upgradeInlineProtocolSession } from "./upgradeSession"
import { InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"

const priorMode = process.env["INLINE_CONFIG_AUTH_SESSION_UPGRADE_MODE"]
const repository = new PermanentAuthorizationKeyRepository(makeAuthorizationKeyCipher({
  activeId: "upgrade-test", keys: new Map([["upgrade-test", new Uint8Array(32).fill(42)]]),
}))
const createCandidate = async () => {
  const key = Uint8Array.from(randomBytes(256))
  const keyId = authKeyId(key)
  await repository.create({ key, keyId, temporary: false, serverSalt: 789n })
  const context: InlineProtocolApplicationContext = {
    authorization: { authKeyId: keyId, permanent: true, temporaryBound: false },
  }
  return { key, keyId, context }
}
const keyRow = async (id: Uint8Array) => (await db.select().from(schema.inlineProtocolAuthKeys)
  .where(eq(schema.inlineProtocolAuthKeys.authKeyId, Buffer.from(id))))[0]!
const sessionRows = () => db.select().from(schema.sessions).orderBy(schema.sessions.id)
const setMode = (mode: "native" | "disabled") => {
  process.env["INLINE_CONFIG_AUTH_SESSION_UPGRADE_MODE"] = mode
  resetServerConfigCacheForTests()
}
const observeUpgrades = () => {
  const events: { level: string; metadata: Record<string, unknown> }[] = []
  const spies = (["info", "warn", "error"] as const).map((level) =>
    spyOn(Log.prototype, level).mockImplementation((message: unknown, metadata?: unknown) => {
      if (message === "legacy_v3_upgrade") events.push({ level, metadata: metadata as Record<string, unknown> })
    }))
  return { events, restore: () => spies.forEach((spy) => spy.mockRestore()) }
}

describe("same-session native V3 upgrade", () => {
  setupTestLifecycle()
  beforeEach(() => setMode("native"))
  afterEach(() => {
    if (priorMode === undefined) delete process.env["INLINE_CONFIG_AUTH_SESSION_UPGRADE_MODE"]
    else process.env["INLINE_CONFIG_AUTH_SESSION_UPGRADE_MODE"] = priorMode
    resetServerConfigCacheForTests()
  })

  test("reports committed cohort IDs and deferred outcomes without credentials or personal data", async () => {
    const user = await testUtils.createUser("telemetry-private@example.test")
    const source = await testUtils.createSessionForUser(user.id, { clientType: "macos" })
    const candidate = await createCandidate()
    const diagnostics = observeUpgrades()
    try {
      await upgradeInlineProtocolSession({}, candidate.context)
      await upgradeInlineProtocolSession({ bearerToken: source.token }, candidate.context)
      expect((await keyRow(candidate.keyId)).accountSessionId).toBe(source.session.id)
      await upgradeInlineProtocolSession({}, candidate.context)
      await upgradeInlineProtocolSession({ bearerToken: `${source.token}-rejected` }, candidate.context)
      setMode("disabled")
      await upgradeInlineProtocolSession({ bearerToken: source.token }, (await createCandidate()).context)
      expect(diagnostics.events.map(({ level, metadata }) => [level, metadata["outcome"]])).toEqual([
        ["info", "not_bound"], ["info", "bound"], ["info", "recovered"],
        ["warn", "source_rejected"], ["info", "disabled"],
      ])
      for (const { metadata } of diagnostics.events) {
        const authorized = metadata["outcome"] === "bound" || metadata["outcome"] === "recovered"
        expect(Object.keys(metadata).sort()).toEqual(authorized
          ? ["duration_ms", "outcome", "phase", "sessionId", "userId"] : ["duration_ms", "outcome", "phase"])
        if (authorized) expect(metadata).toMatchObject({ userId: user.id, sessionId: source.session.id })
        expect(Number.isFinite(metadata["duration_ms"])).toBeTrue()
        expect(metadata["duration_ms"]).toBeGreaterThanOrEqual(0)
      }
      const serialized = JSON.stringify(diagnostics.events)
      for (const privateValue of [source.token, "telemetry-private@example.test", Buffer.from(candidate.key).toString("hex")]) {
        expect(serialized).not.toContain(privateValue)
      }
    } finally {
      diagnostics.restore()
    }
  })

  test("a failing telemetry sink cannot turn a committed upgrade into a failed response", async () => {
    const user = await testUtils.createUser("telemetry-failure@example.test")
    const source = await testUtils.createSessionForUser(user.id, { clientType: "ios" })
    const candidate = await createCandidate()
    const logger = spyOn(Log.prototype, "info").mockImplementation(() => { throw new Error("Unavailable telemetry") })
    try {
      expect((await upgradeInlineProtocolSession({ bearerToken: source.token }, candidate.context)).state.oneofKind).toBe("authorized")
      expect((await keyRow(candidate.keyId)).accountSessionId).toBe(source.session.id)
      expect(await getUserIdFromToken(source.token)).toMatchObject({ userId: user.id, sessionId: source.session.id })
    } finally {
      logger.mockRestore()
    }
  })

  test.each(["ios", "macos"] as const)("preserves the complete %s session and working bearer", async (clientType) => {
    const user = await testUtils.createUser("upgrade@example.test")
    const source = await testUtils.createSessionForUser(user.id, { clientType, deviceId: "original-device" })
    await db.update(schema.sessions).set({
      applePushToken: "synthetic-push-token", pushContentKeyId: "synthetic-push-key", active: false,
      lastActive: new Date(),
    }).where(eq(schema.sessions.id, source.session.id))
    const candidate = await createCandidate()
    const before = await sessionRows()
    const result = await upgradeInlineProtocolSession({ bearerToken: source.token }, candidate.context)
    expect(result.state.oneofKind).toBe("authorized")
    if (result.state.oneofKind !== "authorized") throw new Error("Expected authorization")
    expect(result.state.authorized.accountSessionId).toBe(BigInt(source.session.id))
    expect(result.state.authorized.user?.id).toBe(BigInt(user.id))
    expect(await sessionRows()).toEqual(before)
    expect(await getUserIdFromToken(source.token)).toMatchObject({ userId: user.id, sessionId: source.session.id })
    expect((await repository.getActive(candidate.keyId))?.accountSessionId).toBe(source.session.id)
  })

  test("recovers the exact key after a lost reply and disabled rollout without another session or key", async () => {
    const user = await testUtils.createUser("retry@example.test")
    const source = await testUtils.createSessionForUser(user.id, { clientType: "ios" })
    const candidate = await createCandidate()
    const initial = await upgradeInlineProtocolSession({ bearerToken: source.token }, candidate.context)
    const bound = await keyRow(candidate.keyId)
    setMode("disabled")
    expect(await upgradeInlineProtocolSession({}, candidate.context)).toEqual(initial)
    expect(await upgradeInlineProtocolSession({ bearerToken: source.token }, candidate.context)).toEqual(initial)
    expect(await keyRow(candidate.keyId)).toEqual(bound)
    expect(await sessionRows()).toHaveLength(1)
    const other = await createCandidate()
    expect(await upgradeInlineProtocolSession({ bearerToken: source.token }, other.context)).toEqual({
      state: { oneofKind: "declined", declined: { reason: AuthUpgradeDeclined_Reason.DISABLED } },
    })
    expect((await keyRow(other.keyId)).userId).toBeNull()
  })

  test("a bound key cannot move to a different session, even for the same user", async () => {
    const user = await testUtils.createUser("identity@example.test")
    const first = await testUtils.createSessionForUser(user.id, { clientType: "macos" })
    const second = await testUtils.createSessionForUser(user.id, { clientType: "macos" })
    const candidate = await createCandidate()
    await upgradeInlineProtocolSession({ bearerToken: first.token }, candidate.context)
    const before = await keyRow(candidate.keyId)
    expect(await upgradeInlineProtocolSession({ bearerToken: second.token }, candidate.context)).toEqual({
      state: { oneofKind: "declined", declined: { reason: AuthUpgradeDeclined_Reason.SOURCE_REJECTED } },
    })
    expect(await keyRow(candidate.keyId)).toEqual(before)
  })

  test.each(["web", "cli", "api", "android"] as const)("does not upgrade a %s session", async (clientType) => {
    const user = await testUtils.createUser("ineligible@example.test")
    const source = await testUtils.createSessionForUser(user.id, { clientType })
    const candidate = await createCandidate()
    const before = await sessionRows()
    expect(await upgradeInlineProtocolSession({ bearerToken: source.token }, candidate.context)).toEqual({
      state: { oneofKind: "declined", declined: { reason: AuthUpgradeDeclined_Reason.INELIGIBLE } },
    })
    expect((await keyRow(candidate.keyId)).userId).toBeNull()
    expect(await sessionRows()).toEqual(before)
  })

  test.each(["bot", "deleted", "revoked", "wrong token"] as const)("rejects %s source authority without mutation", async (scenario) => {
    const user = await testUtils.createUser("rejected@example.test")
    const source = await testUtils.createSessionForUser(user.id, { clientType: "ios" })
    if (scenario === "bot") await db.update(schema.users).set({ bot: true }).where(eq(schema.users.id, user.id))
    if (scenario === "deleted") await db.update(schema.users).set({ deleted: true }).where(eq(schema.users.id, user.id))
    if (scenario === "revoked") await db.update(schema.sessions).set({ revoked: new Date() }).where(eq(schema.sessions.id, source.session.id))
    const candidate = await createCandidate()
    const before = { key: await keyRow(candidate.keyId), sessions: await sessionRows() }
    const result = await upgradeInlineProtocolSession({
      bearerToken: scenario === "wrong token" ? `${source.token}wrong` : source.token,
    }, candidate.context)
    expect(result.state.oneofKind).toBe("declined")
    expect({ key: await keyRow(candidate.keyId), sessions: await sessionRows() }).toEqual(before)
  })

  test.each(["revoked", "expired"] as const)("rejects an %s destination key", async (scenario) => {
    const user = await testUtils.createUser("bad-key@example.test")
    const source = await testUtils.createSessionForUser(user.id, { clientType: "ios" })
    const candidate = await createCandidate()
    await db.update(schema.inlineProtocolAuthKeys).set(scenario === "revoked"
      ? { revokedAt: new Date() } : { expiresAt: new Date(0) })
      .where(eq(schema.inlineProtocolAuthKeys.authKeyId, Buffer.from(candidate.keyId)))
    await expect(upgradeInlineProtocolSession({ bearerToken: source.token }, candidate.context)).rejects.toThrow()
    expect((await keyRow(candidate.keyId)).userId).toBeNull()
    expect((await sessionRows())[0]?.revoked).toBeNull()
  })

  test("rejects empty, oversized and malformed bearer input; an absent bearer only observes the candidate", async () => {
    const candidate = await createCandidate()
    for (const bearerToken of ["", "x".repeat(257), "123:\0secret"]) {
      await expect(upgradeInlineProtocolSession({ bearerToken: bearerToken }, candidate.context)).rejects.toThrow()
    }
    expect((await upgradeInlineProtocolSession({ bearerToken: "Bearer 123:token" }, candidate.context)).state.oneofKind).toBe("declined")
    expect(await upgradeInlineProtocolSession({}, candidate.context)).toEqual({ state: { oneofKind: "notBound", notBound: {} } })
    expect((await keyRow(candidate.keyId)).userId).toBeNull()
  })

  test("unbound recovery and rejected sources never wait on the global session mutation lock", async () => {
    const user = await testUtils.createUser("untrusted-probes@example.test")
    const ineligible = await testUtils.createSessionForUser(user.id, { clientType: "cli" })
    const candidate = await createCandidate()
    const acquired = Promise.withResolvers<void>(), release = Promise.withResolvers<void>()
    const owner = db.transaction(async (tx) => {
      await lockGridMutations(tx)
      acquired.resolve()
      await release.promise
    })
    await Promise.race([acquired.promise, owner])
    const requests = Promise.all([
      upgradeInlineProtocolSession({}, candidate.context),
      upgradeInlineProtocolSession({ bearerToken: `${user.id}:invalid` }, candidate.context),
      upgradeInlineProtocolSession({ bearerToken: ineligible.token }, candidate.context),
    ])
    let timer: ReturnType<typeof setTimeout> | undefined
    try {
      const results = await Promise.race([requests, new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(new Error("Unauthenticated probes waited on the global mutation lock")), 10_000)
      })])
      expect(results.map((result) => result.state.oneofKind)).toEqual(["notBound", "declined", "declined"])
      expect((await keyRow(candidate.keyId)).userId).toBeNull()
    } finally {
      if (timer) clearTimeout(timer)
      release.resolve()
      await Promise.allSettled([owner, requests])
    }
  })

  test("concurrent retries converge and a retained bearer can prepare another candidate without replacing the session", async () => {
    const user = await testUtils.createUser("concurrent@example.test")
    const source = await testUtils.createSessionForUser(user.id, { clientType: "macos" })
    const first = await createCandidate(), second = await createCandidate()
    const results = await Promise.allSettled([
      upgradeInlineProtocolSession({ bearerToken: source.token }, first.context),
      upgradeInlineProtocolSession({ bearerToken: source.token }, first.context),
      upgradeInlineProtocolSession({ bearerToken: source.token }, second.context),
    ])
    expect(results.every((result) => result.status === "fulfilled" && result.value.state.oneofKind === "authorized")).toBeTrue()
    expect((await keyRow(first.keyId)).accountSessionId).toBe(source.session.id)
    expect((await keyRow(second.keyId)).accountSessionId).toBe(source.session.id)
    expect(await sessionRows()).toHaveLength(1)
  })

  test("concurrent attempts to bind one key to different sessions elect exactly one immutable binding", async () => {
    const user = await testUtils.createUser("competing@example.test")
    const first = await testUtils.createSessionForUser(user.id, { clientType: "ios" })
    const second = await testUtils.createSessionForUser(user.id, { clientType: "macos" })
    const candidate = await createCandidate()
    const results = await Promise.allSettled([first, second].map((source) =>
      upgradeInlineProtocolSession({ bearerToken: source.token }, candidate.context)))
    const states = results.map((result) => result.status === "fulfilled" ? result.value.state.oneofKind : "error").sort()
    expect(states).toEqual(["authorized", "declined"])
    const boundSessionId = (await keyRow(candidate.keyId)).accountSessionId
    expect(boundSessionId).not.toBeNull()
    expect(boundSessionId === first.session.id || boundSessionId === second.session.id).toBeTrue()
    expect((await sessionRows()).every((session) => session.revoked === null)).toBeTrue()
  })

  test("revocation after upgrade preflight wins before the permanent key is bound", async () => {
    const user = await testUtils.createUser("revocation-race@example.test")
    const source = await testUtils.createSessionForUser(user.id, { clientType: "ios" })
    const candidate = await createCandidate()
    const acquired = Promise.withResolvers<void>(), release = Promise.withResolvers<void>()
    let holderPid = 0
    const revoke = db.transaction(async (tx) => {
      await lockGridMutations(tx)
      const [backend] = await tx.execute<{ pid: number }>(sql`select pg_backend_pid() as pid`)
      holderPid = backend!.pid
      acquired.resolve()
      await release.promise
      await revokeSessionInTransaction(tx, { actor: "system", targetUserId: user.id, sessionId: source.session.id })
    })
    await Promise.race([acquired.promise, revoke])
    const upgrading = upgradeInlineProtocolSession({ bearerToken: source.token }, candidate.context)
    const outcomes = Promise.allSettled([revoke, upgrading])
    try {
      // The source is still valid until the upgrade has passed its unlocked checks and
      // actually queued on our advisory lock. Without this barrier a revoked-source
      // preflight rejection would pass the test even if commit-time revalidation broke.
      const deadline = performance.now() + 2_000
      let blocked = false
      while (performance.now() < deadline) {
        const [row] = await db.execute<{ blocked: boolean }>(sql`
          select exists(select 1 from pg_stat_activity
            where datname = current_database() and wait_event = 'advisory'
              and ${holderPid} = any(pg_blocking_pids(pid))) as blocked
        `)
        if (row?.blocked) { blocked = true; break }
        await Bun.sleep(10)
      }
      expect(blocked).toBeTrue()
      release.resolve()
      const results = await outcomes
      expect(results[0]?.status).toBe("fulfilled")
      if (results[1]?.status !== "fulfilled") throw new Error("Expected rejected source result")
      expect(results[1].value).toEqual({
        state: { oneofKind: "declined", declined: { reason: AuthUpgradeDeclined_Reason.SOURCE_REJECTED } },
      })
      expect((await keyRow(candidate.keyId)).userId).toBeNull()
      expect((await upgradeInlineProtocolSession({ bearerToken: source.token }, candidate.context)).state.oneofKind).toBe("declined")
      expect(await upgradeInlineProtocolSession({}, candidate.context)).toEqual({ state: { oneofKind: "notBound", notBound: {} } })
      await expect(getUserIdFromToken(source.token)).rejects.toThrow()
    } finally {
      release.resolve()
      await outcomes
    }
  })

  test("a failed key commit leaves the bearer and complete session intact without reporting success", async () => {
    const user = await testUtils.createUser("write-failure@example.test")
    const source = await testUtils.createSessionForUser(user.id, { clientType: "ios" })
    const candidate = await createCandidate()
    const before = { key: await keyRow(candidate.keyId), sessions: await sessionRows() }
    await db.execute(sql`CREATE FUNCTION test_reject_upgrade() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN RAISE EXCEPTION 'test upgrade write failure'; END $$;
      CREATE CONSTRAINT TRIGGER test_reject_upgrade AFTER UPDATE ON inline_protocol_auth_keys
      DEFERRABLE INITIALLY DEFERRED
      FOR EACH ROW EXECUTE FUNCTION test_reject_upgrade();`)
    const diagnostics = observeUpgrades()
    try {
      let failure: unknown
      try {
        await upgradeInlineProtocolSession({ bearerToken: source.token }, candidate.context)
      } catch (error) {
        failure = error
      }
      expect(failure).toBeInstanceOf(InlineError)
      if (!(failure instanceof InlineError)) throw new Error("Expected a sanitized internal error")
      expect(failure.type).toBe(InlineError.ApiError.INTERNAL[0])
      expect(failure.message).toBe(InlineError.ApiError.INTERNAL[2])
      expect(failure.cause).toBeUndefined()
      expect({ key: await keyRow(candidate.keyId), sessions: await sessionRows() }).toEqual(before)
      expect(diagnostics.events).toHaveLength(1)
      expect(diagnostics.events[0]).toMatchObject({ level: "error", metadata: { outcome: "internal_error", phase: "transaction" } })
      expect(Object.keys(diagnostics.events[0]!.metadata).sort()).toEqual(["duration_ms", "outcome", "phase"])
      expect(JSON.stringify(diagnostics.events)).not.toContain("test upgrade write failure")
    } finally {
      diagnostics.restore()
      await db.execute(sql`DROP TRIGGER test_reject_upgrade ON inline_protocol_auth_keys; DROP FUNCTION test_reject_upgrade();`)
    }
    expect((await upgradeInlineProtocolSession({ bearerToken: source.token }, candidate.context)).state.oneofKind).toBe("authorized")
    await db.update(schema.sessions).set({ revoked: new Date() }).where(eq(schema.sessions.id, source.session.id))
    expect((await upgradeInlineProtocolSession({}, candidate.context)).state.oneofKind).toBe("declined")
    expect(await repository.getActive(candidate.keyId)).toBeUndefined()
  })

  test("encrypted dispatcher recovers with a fresh request identity and refuses temporary-key upgrades", async () => {
    const user = await testUtils.createUser("encrypted-upgrade@example.test")
    const source = await testUtils.createSessionForUser(user.id, { clientType: "macos" })
    const candidate = await createCandidate()
    const now = Date.now(), sessionId = 987n
    const temporary = new TemporaryAuthorizationKeyStore(() => Math.floor(now / 1_000))
    const authorizationKeys = new InlineProtocolAuthorizationKeys(repository, temporary)
    const operations = new InlineProtocolOperations(new InlineProtocolAuthOperations({
      activeId: "test", keys: new Map([["test", new Uint8Array(32).fill(1)]]),
    }))
    const application = makeInlineProtocolApplicationDispatcher({ operations, authorizationKeys, connectionId: "upgrade-test" })
    const rsa = generateKeyPairSync("rsa", { modulusLength: 2048, publicExponent: 65537 })
    const jwk = rsa.publicKey.export({ format: "jwk" })
    const replay = makeInlineProtocolReplayRepository(new InlineProtocolReplayRepository())
    const secure = new InlineProtocolServerSession({
      rsaKeys: [{ ...makeRsaPublicKey(Buffer.from(jwk.n!, "base64url"), Buffer.from(jwk.e!, "base64url")),
        rawDecrypt: (bytes) => privateDecrypt({ key: rsa.privateKey, padding: constants.RSA_NO_PADDING }, bytes) }],
      authorizationKeys, replay, application, nowMilliseconds: () => now,
      randomBytes: (length) => randomBytes(length),
      gunzip: (packed, maximum) => gunzipSync(packed, { maxOutputLength: maximum }),
    })
    const ids = new MessageIdGenerator()
    const invoke = async (input: AuthUpgradeSessionRequest, sequenceNumber: number) => {
      const body = encodeInlineInvoke(RealtimeV3Request.toBinary({ body: { oneofKind: "authUpgradeSession", authUpgradeSession: input } }))
      const responses = await secure.receive(encryptRecord(candidate.key, "client-to-server", {
        serverSalt: 789n, sessionId, messageId: ids.next(now, sequenceNumber, 0), sequenceNumber, body,
      }, randomBytes(12 + ((16 - ((32 + body.length + 12) % 16)) % 16))))
      const result = responses.map((record) => decryptRecord(record, candidate.key, {
        direction: "server-to-client", sessionId, validServerSalts: new Set([789n]), nowSeconds: now / 1_000,
      }).body).find((body) => serviceConstructor(body) === ServiceConstructor.rpcResult)
      if (!result) throw new Error("Encrypted result missing")
      const decoded = decodeInlineApplicationObject(decodeRpcResult(result).result)
      if (decoded.kind !== "result") throw new Error("Expected application result")
      return RealtimeV3Response.fromBinary(decoded.payload)
    }
    try {
      const first = await invoke({ bearerToken: source.token }, 1)
      expect(first.body.oneofKind).toBe("authUpgradeSession")
      setMode("disabled")
      // No bearer and no prior transport result are required for recovery.
      expect(await invoke({}, 3)).toEqual(first)
      expect(await db.select().from(schema.inlineProtocolRequests)).toHaveLength(2)
      const rejected = await application.dispatch({
        payload: RealtimeV3Request.toBinary({ body: { oneofKind: "authUpgradeSession", authUpgradeSession: { bearerToken: source.token } } }),
        authorization: { authKeyId: candidate.keyId, permanent: false, temporaryBound: false },
        messageId: 1n, sessionId: 1n, signal: new AbortController().signal,
        markExecutionStarted: () => { throw new Error("Temporary key must not execute upgrade") }, sendUpdate() {},
      })
      if (rejected.kind !== "result") throw new Error("Expected rejection")
      const response = RealtimeV3Response.fromBinary(rejected.payload)
      expect(response.body.oneofKind).toBe("rpcError")
      if (response.body.oneofKind === "rpcError") expect(response.body.rpcError.errorCode).toBe(RpcError_Code.UNAUTHENTICATED)
    } finally {
      replay.close()
    }
  })

  test("an upgraded key binds a real temporary carrier and serves getMe while V2 keeps the same session", async () => {
    const user = await testUtils.createUser("coexisting-protocols@example.test")
    const source = await testUtils.createSessionForUser(user.id, { clientType: "ios", deviceId: "retained-device" })
    await db.update(schema.sessions).set({
      lastActive: new Date(), applePushToken: "retained-push-token", pushContentKeyId: "retained-push-key",
    }).where(eq(schema.sessions.id, source.session.id))
    const before = await sessionRows()
    const candidate = await createCandidate()
    const now = Date.now()
    const temporary = new TemporaryAuthorizationKeyStore(() => Math.floor(now / 1_000))
    const authorizationKeys = new InlineProtocolAuthorizationKeys(repository, temporary)
    const operations = new InlineProtocolOperations(new InlineProtocolAuthOperations({
      activeId: "test", keys: new Map([["test", new Uint8Array(32).fill(1)]]),
    }))
    const admitted: { userId: number | undefined; sessionId: number | undefined }[] = []
    const application = makeInlineProtocolApplicationDispatcher({
      operations, authorizationKeys, connectionId: "coexisting-protocols-test",
      onAuthorized: (authorization) => {
        admitted.push({ userId: authorization.userId, sessionId: authorization.accountSessionId })
        return true
      },
    })
    const rsa = generateKeyPairSync("rsa", { modulusLength: 2048, publicExponent: 65537 })
    const jwk = rsa.publicKey.export({ format: "jwk" })
    const replay = makeInlineProtocolReplayRepository(new InlineProtocolReplayRepository())
    const makeCarrier = (key: Uint8Array, sessionId: bigint) => {
      const secure = new InlineProtocolServerSession({
        rsaKeys: [{ ...makeRsaPublicKey(Buffer.from(jwk.n!, "base64url"), Buffer.from(jwk.e!, "base64url")),
          rawDecrypt: (bytes) => privateDecrypt({ key: rsa.privateKey, padding: constants.RSA_NO_PADDING }, bytes) }],
        authorizationKeys, replay, application, nowMilliseconds: () => now,
        randomBytes: (length) => randomBytes(length),
        gunzip: (packed, maximum) => gunzipSync(packed, { maxOutputLength: maximum }),
      })
      const ids = new MessageIdGenerator()
      let sequenceNumber = 1
      return async (buildBody: (messageId: bigint) => Uint8Array) => {
        const messageId = ids.next(now, sequenceNumber, 0)
        const body = buildBody(messageId)
        const responses = await secure.receive(encryptRecord(key, "client-to-server", {
          serverSalt: 789n, sessionId, messageId, sequenceNumber, body,
        }, randomBytes(12 + ((16 - ((32 + body.length + 12) % 16)) % 16))))
        sequenceNumber += 2
        const result = responses.map((record) => decryptRecord(record, key, {
          direction: "server-to-client", sessionId, validServerSalts: new Set([789n]), nowSeconds: now / 1_000,
        }).body).filter((body) => serviceConstructor(body) === ServiceConstructor.rpcResult)
          .map(decodeRpcResult).find((result) => result.requestMessageId === messageId)
        if (!result) throw new Error("Encrypted result missing for this request")
        return result.result
      }
    }
    const decodeApplication = (body: Uint8Array) => {
      const decoded = decodeInlineApplicationObject(body)
      if (decoded.kind !== "result") throw new Error("Expected application result")
      return RealtimeV3Response.fromBinary(decoded.payload)
    }
    try {
      const permanentCarrier = makeCarrier(candidate.key, 101n)
      const upgraded = decodeApplication(await permanentCarrier(() => encodeInlineInvoke(RealtimeV3Request.toBinary({
        body: { oneofKind: "authUpgradeSession", authUpgradeSession: { bearerToken: source.token } },
      }))))
      expect(upgraded.body.oneofKind).toBe("authUpgradeSession")
      if (upgraded.body.oneofKind !== "authUpgradeSession") throw new Error("Expected upgrade result")
      expect(upgraded.body.authUpgradeSession.state).toMatchObject({
        oneofKind: "authorized", authorized: { accountSessionId: BigInt(source.session.id) },
      })

      const temporaryKey = Uint8Array.from(randomBytes(256))
      const temporaryId = authKeyId(temporaryKey)
      const temporarySessionId = 202n, nonce = 303n
      const expiresAt = Math.floor(now / 1_000) + 600
      await authorizationKeys.create({
        key: temporaryKey, keyId: temporaryId, temporary: true, serverSalt: 789n, expiresAt,
      })
      const temporaryCarrier = makeCarrier(temporaryKey, temporarySessionId)
      // Use the real encrypted proof verifier; assigning a test binding directly would hide
      // an upgrade that returns success but cannot authorize a subsequent V3 connection.
      await temporaryCarrier((messageId) => encodeBindTempAuthKey({
        permanentAuthKeyId: readInt64LE(candidate.keyId, 0), nonce, expiresAt,
        encryptedMessage: createTemporaryKeyBindingProof({
          permanentAuthKey: candidate.key, temporaryAuthKey: temporaryKey, temporarySessionId,
          messageId, nonce, expiresAt, randomInt128: randomBytes(16), randomPadding: randomBytes(8),
        }),
      }))
      expect((await authorizationKeys.load(temporaryId))?.binding).toMatchObject({
        userId: user.id, accountSessionId: source.session.id, permanentAuthKeyId: candidate.keyId,
      })
      const getMeCall = { method: Method.GET_ME, input: { oneofKind: "getMe" as const, getMe: {} } }
      const v3 = decodeApplication(await temporaryCarrier(() => encodeInlineInvoke(RealtimeV3Request.toBinary({
        body: { oneofKind: "rpc", rpc: getMeCall },
      }))))
      expect(v3.body.oneofKind).toBe("rpcResult")
      if (v3.body.oneofKind !== "rpcResult") throw new Error("Expected getMe RPC result")
      expect(v3.body.rpcResult.result).toMatchObject({ oneofKind: "getMe", getMe: { user: { id: BigInt(user.id) } } })
      expect(admitted).toEqual([{ userId: user.id, sessionId: source.session.id }])

      const legacyIdentity = await getUserIdFromToken(source.token)
      expect(legacyIdentity).toMatchObject({ userId: user.id, sessionId: source.session.id })
      const v2 = await handleRpcCall(getMeCall, {
        ...legacyIdentity, connectionId: "still-connected-v2", sendRaw() {}, sendRpcReply() {},
      })
      expect(v2).toEqual(v3.body.rpcResult.result)
      expect(await sessionRows()).toEqual(before)
    } finally {
      replay.close()
    }
  })
})
