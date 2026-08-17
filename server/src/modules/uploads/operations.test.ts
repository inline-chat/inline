import { createHash } from "node:crypto"
import { describe, expect, setDefaultTimeout, test } from "bun:test"
import { UploadKind, UploadStatus, type UploadComplete } from "@inline-chat/protocol/core"
import { authKeyId } from "@inline-chat/protocol/secure"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { PermanentAuthorizationKeyRepository } from "@in/server/db/models/inlineProtocol"
import { InlineUploadRepository } from "@in/server/db/models/inlineUploads"
import { makeAuthorizationKeyCipher } from "@in/server/modules/inlineProtocol/keyCipher"
import type { HandlerContext } from "@in/server/realtime/types"
import type { MediaUploadFinalizer } from "./finalizer"
import { NativeUploadOperations } from "./operations"
import type { UploadPartStore } from "./partStore"

setDefaultTimeout(20_000)

const authorizationKeys = () => new PermanentAuthorizationKeyRepository(
  makeAuthorizationKeyCipher({
    activeId: "test",
    keys: new Map([["test", new Uint8Array(32).fill(0x31)]]),
  }),
)

const context = (
  userId: number,
  sessionId: number,
  permanentAuthKeyId: Uint8Array,
): HandlerContext => ({
  userId,
  sessionId,
  connectionId: "native-upload-test",
  sendRaw: () => {},
  sendRpcReply: () => {},
  inlineProtocol: { permanentAuthKeyId },
})

class MemoryPartStore implements UploadPartStore {
  readonly objects = new Map<string, Uint8Array>()

  async put(input: {
    uploadId: Uint8Array
    partIndex: number
    sha256: Uint8Array
    data: Uint8Array
  }): Promise<string> {
    const key = `${Buffer.from(input.uploadId).toString("hex")}/${input.partIndex}`
    this.objects.set(key, input.data.slice())
    return key
  }

  async read(key: string): Promise<Uint8Array> {
    const bytes = this.objects.get(key)
    if (!bytes) throw new Error("missing test object")
    return bytes.slice()
  }

  async remove(key: string): Promise<void> {
    this.objects.delete(key)
  }
}

const complete: UploadComplete = {
  fileUniqueId: "INDnative",
  media: { oneofKind: undefined },
}

const finalizer: MediaUploadFinalizer = {
  async finalize({ upload, parts }) {
    expect(parts.map(({ partIndex }) => partIndex)).toEqual([0])
    expect(upload.kind).toBe("document")
    return { fileUniqueId: complete.fileUniqueId, mediaId: 44, complete }
  },
  async project(_kind, fileUniqueId) {
    return { ...complete, fileUniqueId }
  },
}

describe("native upload operations", () => {
  setupTestLifecycle()

  test("runs create, durable save, reconciliation, finish, and cached finish", async () => {
    const user = await testUtils.createUser("native-upload-operations@example.com")
    const account = await testUtils.createSessionForUser(user.id)
    const permanentKey = new Uint8Array(256).fill(0x51)
    const permanentKeyId = authKeyId(permanentKey)
    const keys = authorizationKeys()
    await keys.create({ key: permanentKey, keyId: permanentKeyId, serverSalt: 1n, temporary: false })
    await keys.authorize(permanentKeyId, user.id, account.session.id)

    const store = new MemoryPartStore()
    const operations = new NativeUploadOperations(
      new InlineUploadRepository(),
      store,
      finalizer,
    )
    const requestContext = context(user.id, account.session.id, permanentKeyId)
    const body = new TextEncoder().encode("native upload body")
    const create = await operations.create({
      clientUploadId: new Uint8Array(16).fill(3),
      fileName: "proof.bin",
      mimeType: "application/octet-stream",
      byteCount: BigInt(body.length),
      sha256: createHash("sha256").update(body).digest(),
      kind: UploadKind.DOCUMENT,
      metadata: { oneofKind: undefined },
    }, requestContext)
    expect(create.partCount).toBe(1)
    expect(create.acceptedParts).toEqual([])

    expect(await operations.finish({ uploadId: create.uploadId }, requestContext))
      .toEqual({ state: { oneofKind: "missing", missing: { partIndices: [0] } } })
    expect(await operations.savePart({
      uploadId: create.uploadId,
      partIndex: 0,
      data: body,
    }, requestContext)).toEqual({ alreadyPresent: false })
    expect(await operations.savePart({
      uploadId: create.uploadId,
      partIndex: 0,
      data: body,
    }, requestContext)).toEqual({ alreadyPresent: true })
    expect(await operations.state({ uploadId: create.uploadId }, requestContext))
      .toMatchObject({ status: UploadStatus.UPLOADING, acceptedParts: [0] })

    expect(await operations.finish({ uploadId: create.uploadId }, requestContext))
      .toEqual({ state: { oneofKind: "complete", complete } })
    expect(store.objects.size).toBe(0)
    expect(await operations.finish({ uploadId: create.uploadId }, requestContext))
      .toEqual({ state: { oneofKind: "complete", complete } })
  })
})
