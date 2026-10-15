import { expect, test } from "bun:test"
import { generateKeyPairSync } from "node:crypto"
import { createInterface } from "node:readline"
import { Readable } from "node:stream"
import {
  GetUpdatesResult_ResultType, Method,
  type RealtimeV3Update, type RpcCall, type RpcResult,
} from "@inline-chat/protocol/core"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { db } from "@in/server/db"
import { PermanentAuthorizationKeyRepository } from "@in/server/db/models/inlineProtocol"
import { makeAuthorizationKeyCipher } from "@in/server/modules/inlineProtocol/keyCipher"
import { makeInlineProtocolRsaSigner } from "@in/server/modules/inlineProtocol/rsaSigner"
import { sendMessage } from "@in/server/functions/messages.sendMessage"
import { revokeSession } from "@in/server/modules/sessions/revokeSession"
import { sql } from "drizzle-orm"

setupTestLifecycle()

type Authorization = {
  key: Uint8Array; keyId: Uint8Array; serverSalt: bigint; temporary: boolean; expiresAt?: number
}
type Credentials = { permanent: Authorization; temporary?: Authorization }
type PublicKey = { modulus: string; exponent: string; fingerprint: string }
type ClientOptions = {
  url: string; rsaPublicKeys: readonly PublicKey[]; connectTimeoutMs: number; requestTimeoutMs: number
  onCredentials?: (credentials: Credentials) => void
  onUpdate?: (update: RealtimeV3Update) => void
}
type AuthenticatedClient = {
  readonly credentials: Credentials | undefined
  connect(credentials: Credentials): Promise<void>
  callRpc(call: RpcCall): Promise<RpcResult["result"]>
  close(): Promise<void>
}
type ProtocolClient = {
  readonly authorization: Authorization
  probeTemporaryAuthorization(): Promise<void>
  close(): Promise<void>
}

// Exercise the actual SDK implementation without introducing a production SDK
// dependency into the server. This fixture boundary only describes what it uses;
// the SDK's own project remains responsible for compiling its implementation.
const loadClients = async () => {
  const base = new URL("../../../../packages/sdk/src/realtime/", import.meta.url)
  const client = await import(new URL("v3-client.ts", base).href) as {
    InlineRealtimeV3Client: new (options: ClientOptions) => AuthenticatedClient
  }
  const connection = await import(new URL("v3-connection.ts", base).href) as {
    InlineProtocolV3Connection: { connect(options: ClientOptions & { authorization?: Authorization }): Promise<ProtocolClient> }
  }
  return { ...client, ...connection }
}

const bounded = async <T>(operation: PromiseLike<T>, label: string, milliseconds = 10_000): Promise<T> => {
  let timer: ReturnType<typeof setTimeout> | undefined
  try {
    return await Promise.race([operation, new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new Error(`Timed out: ${label}`)), milliseconds)
    })])
  } finally { clearTimeout(timer) }
}

async function startOrigin(databaseUrl: string, rsaPrivateKeysJson: string) {
  const child = Bun.spawn({
    cmd: [process.execPath, "--no-env-file", "src/modules/internalMessaging/v3OriginRecovery.worker.ts"],
    cwd: import.meta.dir + "/../../..",
    env: {
      ...process.env, DATABASE_URL: databaseUrl, TEST_DATABASE_URL: databaseUrl,
      REDIS_URL: "", VALKEY_URL: "", INLINE_REALTIME_DISTRIBUTED: "1",
      INLINE_TEST_V3_RSA_KEYS: rsaPrivateKeysJson,
      SESSION_AUTHORITY_RECONCILIATION_INTERVAL_MS: "1000", SESSION_AUTHORITY_MAX_AGE_MS: "10000",
    },
    stdin: "pipe", stdout: "pipe", stderr: "pipe",
  })
  let output = ""
  const signals = new Map<string, ReturnType<typeof Promise.withResolvers<string>>>()
  const signal = (key: string) => {
    let value = signals.get(key)
    if (!value) { value = Promise.withResolvers<string>(); signals.set(key, value) }
    return value
  }
  const readers = Promise.all([child.stdout, child.stderr].map(async (stream) => {
    for await (const line of createInterface({ input: Readable.fromWeb(stream as never) })) {
      if (line.startsWith("V3_ORIGIN:PORT:")) signal("PORT").resolve(line.slice("V3_ORIGIN:PORT:".length))
      else if (line.startsWith("V3_ORIGIN:")) signal(line.slice("V3_ORIGIN:".length)).resolve("")
      else output = (output + line + "\n").slice(-8_000)
    }
  }))
  const wait = (name: string) => bounded(Promise.race([
    signal(name).promise,
    child.exited.then((code): never => { throw new Error(`Origin exited before ${name}: ${code}; ${output}`) }),
  ]), `origin ${name}; ${output}`)
  let stopPromise: Promise<void> | undefined
  const stop = (): Promise<void> => stopPromise ??= (async () => {
    try {
      child.stdin.write("STOP\n")
      child.stdin.end()
      const code = await bounded(child.exited, `graceful origin exit; ${output}`)
      expect(code).toBe(0)
    } catch (error) {
      child.kill()
      await child.exited
      throw error
    } finally { await readers }
  })()
  try {
    const port = Number(await wait("PORT"))
    return {
      url: `ws://127.0.0.1:${port}/realtime/v3`, httpUrl: `http://127.0.0.1:${port}`,
      command: async (command: string, response: string) => { child.stdin.write(command + "\n"); await wait(response) },
      stop,
    }
  } catch (error) {
    child.kill()
    await child.exited
    await readers
    throw error
  }
}

test("V3 recovers cached authorization across origins, catches up without Redis, and revokes both live origins", async () => {
  const previousDistributed = process.env["INLINE_REALTIME_DISTRIBUTED"]
  process.env["INLINE_REALTIME_DISTRIBUTED"] = "1"
  const clients: Array<{ close(): Promise<void> }> = []
  const origins: Awaited<ReturnType<typeof startOrigin>>[] = []
  const failures: unknown[] = []
  try {
    const { InlineRealtimeV3Client, InlineProtocolV3Connection } = await loadClients()
    const rsaPrivateKeysJson = JSON.stringify(Array.from({ length: 2 }, () => ({
      privateKeyPem: generateKeyPairSync("rsa", { modulusLength: 2048 }).privateKey.export({ type: "pkcs8", format: "pem" }),
    })))
    const rsaPublicKeys = makeInlineProtocolRsaSigner(rsaPrivateKeysJson).publicKeyRing
    const [database] = await db.execute<{ name: string }>(sql`select current_database() as name`)
    if (!database) throw new Error("Missing isolated database")
    const databaseUrl = new URL(process.env["TEST_DATABASE_URL"]!)
    databaseUrl.pathname = "/" + database.name
    const first = await startOrigin(databaseUrl.toString(), rsaPrivateKeysJson)
    origins.push(first)
    const second = await startOrigin(databaseUrl.toString(), rsaPrivateKeysJson)
    origins.push(second)
    const options = (url: string): ClientOptions => ({ url, rsaPublicKeys, connectTimeoutMs: 5_000, requestTimeoutMs: 5_000 })
    const recipient = await testUtils.createUser("v3-origin-recipient@test.invalid")
    const targetSession = await testUtils.createSessionForUser(recipient.id)
    const observerSession = await testUtils.createSessionForUser(recipient.id)
    const sender = await testUtils.createUser("v3-origin-sender@test.invalid")
    const chat = await testUtils.createPrivateChat(sender, recipient)
    if (!chat) throw new Error("Missing private chat")
    const repository = new PermanentAuthorizationKeyRepository(makeAuthorizationKeyCipher({
      activeId: "fixture", keys: new Map([["fixture", new Uint8Array(32).fill(0x71)]]),
    }))
    const permanentFor = async (sessionId: number) => {
      const login = await InlineProtocolV3Connection.connect(options(first.url))
      clients.push(login)
      const permanent = login.authorization
      expect(await repository.authorize(permanent.keyId, recipient.id, sessionId)).toBe(true)
      await login.close()
      return permanent
    }
    const permanent = await permanentFor(targetSession.session.id)
    const firstClient = new InlineRealtimeV3Client(options(first.url))
    clients.push(firstClient)
    await firstClient.connect({ permanent })
    const original = firstClient.credentials
    if (!original?.temporary) throw new Error("Origin did not create temporary authorization")
    const getMe: RpcCall = { method: Method.GET_ME, input: { oneofKind: "getMe", getMe: {} } }
    expect((await firstClient.callRpc(getMe)).oneofKind).toBe("getMe")

    // B shares the durable permanent key, never A's process-local temporary key.
    const forgotten = await InlineProtocolV3Connection.connect({ ...options(second.url), authorization: original.temporary })
    clients.push(forgotten)
    await expect(forgotten.probeTemporaryAuthorization()).rejects.toMatchObject({ code: "unauthorized" })
    await forgotten.close()
    expect(await repository.getActive(permanent.keyId)).toBeDefined()

    const updates: RealtimeV3Update[] = []
    let updateArrived = Promise.withResolvers<void>()
    const replacements: Credentials[] = []
    const secondClient = new InlineRealtimeV3Client({
      ...options(second.url),
      onCredentials: (credentials) => { replacements.push(credentials) },
      onUpdate: (update) => { updates.push(update); updateArrived.resolve(); updateArrived = Promise.withResolvers<void>() },
    })
    clients.push(secondClient)
    await secondClient.connect(original)
    expect(replacements).toHaveLength(1)
    expect(secondClient.credentials?.permanent.keyId).toEqual(permanent.keyId)
    expect(secondClient.credentials?.temporary?.keyId).not.toEqual(original.temporary.keyId)
    const me = await secondClient.callRpc(getMe)
    if (me.oneofKind !== "getMe") throw new Error("Unexpected getMe response")
    expect(me.getMe.user?.id).toBe(BigInt(recipient.id))
    await Promise.all(origins.map((origin) => origin.command("ADMISSION_IDLE", "ADMISSION_IDLE")))

    // A different account session on B must survive revoking the shared target.
    const observer = new InlineRealtimeV3Client(options(second.url))
    clients.push(observer)
    await observer.connect({ permanent: await permanentFor(observerSession.session.id) })
    expect((await observer.callRpc(getMe)).oneofKind).toBe("getMe")
    updates.length = 0
    const sent = await sendMessage({
      peerId: { type: { oneofKind: "chat", chat: { chatId: BigInt(chat.id) } } },
      message: "Durable message while both V3 origins are active", randomId: 712345n,
    }, testUtils.functionContext({ userId: sender.id }))
    const message = sent.updates.find((update) => update.update.oneofKind === "newMessage")
    if (message?.update.oneofKind !== "newMessage" || !message.update.newMessage.message) throw new Error("Missing committed message")
    const hasHint = () => updates.some((update) => update.message?.payload.oneofKind === "update" &&
      update.message.payload.update.updates.some((item) => item.update.oneofKind === "chatHasNewUpdates" &&
        item.update.chatHasNewUpdates.chatId === BigInt(chat.id) && item.update.chatHasNewUpdates.updateSeq >= 1))
    await bounded((async () => { while (!hasHint()) await updateArrived.promise })(), "automatic brokerless V3 durable hint", 5_000)
    const recovered = await secondClient.callRpc({
      method: Method.GET_UPDATES, input: { oneofKind: "getUpdates", getUpdates: {
        bucket: { type: { oneofKind: "chat", chat: { peerId: { type: { oneofKind: "chat", chat: { chatId: BigInt(chat.id) } } } } } },
        startSeq: 0n, seqEnd: 0n, limit: 100, totalLimit: 0,
      } },
    })
    if (recovered.oneofKind !== "getUpdates") throw new Error("Unexpected catch-up response")
    expect(recovered.getUpdates.resultType).toBe(GetUpdatesResult_ResultType.SLICE)
    expect(recovered.getUpdates.updates.some((update) => update.update.oneofKind === "newMessage" &&
      update.update.newMessage.message?.message === "Durable message while both V3 origins are active")).toBe(true)
    expect(recovered.getUpdates.sidecars?.users.some((user) => user.id === BigInt(sender.id))).toBe(true)

    expect((await revokeSession({ actor: "system", targetUserId: recipient.id, sessionId: targetSession.session.id })).revoked).toBe(true)
    // Neither child has Redis. Real periodic DB authority reconciliation closes
    // both sockets; no manual reconciliation or injected broker event is used.
    await Promise.all(origins.map((origin) => origin.command(`WAIT_REVOKED:${targetSession.session.id}`, "REVOKED")))
    // Registry removal precedes the remote close event. If that event arrives
    // during this RPC the SDK reports unauthorized; if already received it
    // reports closed. Neither origin may successfully execute the RPC.
    const revokedOrClosed = { code: expect.stringMatching(/^(unauthorized|closed)$/) }
    await expect(firstClient.callRpc(getMe)).rejects.toMatchObject(revokedOrClosed)
    await expect(secondClient.callRpc(getMe)).rejects.toMatchObject(revokedOrClosed)
    expect((await observer.callRpc(getMe)).oneofKind).toBe("getMe")

    await first.stop()
    expect((await fetch(second.httpUrl + "/readyz")).status).toBe(200)
    expect((await observer.callRpc(getMe)).oneofKind).toBe("getMe")
  } catch (error) { failures.push(error) }
  finally {
    const closed = await Promise.allSettled(clients.map((client) => client.close()))
    const stopped = await Promise.allSettled(origins.map((origin) => origin.stop()))
    for (const result of [...closed, ...stopped]) {
      if (result.status === "rejected") failures.push(result.reason)
    }
    if (previousDistributed === undefined) Reflect.deleteProperty(process.env, "INLINE_REALTIME_DISTRIBUTED")
    else process.env["INLINE_REALTIME_DISTRIBUTED"] = previousDistributed
  }
  if (failures.length) throw new AggregateError(failures, "V3 origin recovery failed")
}, 45_000)
