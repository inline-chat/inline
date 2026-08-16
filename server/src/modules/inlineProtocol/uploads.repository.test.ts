import { describe, expect, setDefaultTimeout, test } from "bun:test"
import { eq } from "drizzle-orm"
import { authKeyId } from "@inline-chat/protocol/secure"
import { db, schema } from "@in/server/db"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { PermanentAuthorizationKeyRepository } from "@in/server/db/models/inlineProtocol"
import { InlineProtocolUploadRepository } from "@in/server/db/models/inlineProtocolUploads"
import { makeAuthorizationKeyCipher } from "./keyCipher"

setDefaultTimeout(20_000)

const keys = () => new PermanentAuthorizationKeyRepository(makeAuthorizationKeyCipher({
  activeId: "test",
  keys: new Map([["test", new Uint8Array(32).fill(0x31)]]),
}))

const metadata = {
  fileName: "rotation-proof.txt",
  mimeType: "text/plain",
  byteCount: 4n,
  sha256: new Uint8Array(32).fill(0x42),
  kind: "document" as const,
}

describe("Inline Protocol upload ownership", () => {
  setupTestLifecycle()

  test("survives temporary-key rotation and rejects a revoked permanent authorization", async () => {
    const user = await testUtils.createUser("v3-upload-key-revocation@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const permanentKey = new Uint8Array(256).fill(0x11)
    const permanentKeyId = authKeyId(permanentKey)
    const authorizations = keys()
    await authorizations.create({ key: permanentKey, keyId: permanentKeyId, serverSalt: 1n, temporary: false })
    await authorizations.authorize(permanentKeyId, user.id, account.session.id)

    const uploads = new InlineProtocolUploadRepository()
    const intent = await uploads.create({
      userId: user.id,
      accountSessionId: account.session.id,
      permanentAuthKeyId: permanentKeyId,
      temporaryAuthKeyId: new Uint8Array(8).fill(0x21),
    }, metadata)

    expect(await uploads.finish(intent.uploadId, {
      userId: user.id,
      accountSessionId: account.session.id,
      permanentAuthKeyId: permanentKeyId,
    })).toEqual({ kind: "pending" })
    const firstClaim = await uploads.claim(intent.uploadId, intent.capability)
    expect(firstClaim.kind).toBe("claimed")
    if (firstClaim.kind === "claimed") await uploads.release(firstClaim.upload)

    await authorizations.revoke(permanentKeyId)
    expect(await uploads.claim(intent.uploadId, intent.capability)).toEqual({ kind: "rejected" })
  })

  test("rejects an upload capability after its account session is revoked", async () => {
    const user = await testUtils.createUser("v3-upload-session-revocation@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const permanentKey = new Uint8Array(256).fill(0x12)
    const permanentKeyId = authKeyId(permanentKey)
    const authorizations = keys()
    await authorizations.create({ key: permanentKey, keyId: permanentKeyId, serverSalt: 2n, temporary: false })
    await authorizations.authorize(permanentKeyId, user.id, account.session.id)

    const uploads = new InlineProtocolUploadRepository()
    const intent = await uploads.create({
      userId: user.id,
      accountSessionId: account.session.id,
      permanentAuthKeyId: permanentKeyId,
      temporaryAuthKeyId: new Uint8Array(8).fill(0x22),
    }, metadata)
    await db.update(schema.sessions).set({ revoked: new Date() })
      .where(eq(schema.sessions.id, account.session.id))

    expect(await uploads.claim(intent.uploadId, intent.capability)).toEqual({ kind: "rejected" })
  })
})
