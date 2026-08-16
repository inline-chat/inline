import { describe, expect, test } from "bun:test"
import { createHash } from "node:crypto"
import type {
  ClaimedInlineProtocolUpload,
  InlineProtocolUploadRepository,
} from "@in/server/db/models/inlineProtocolUploads"
import { InlineProtocolUploadOperations } from "./uploads"

const uploadId = Uint8Array.from({ length: 16 }, (_, index) => index + 1)
const capability = Uint8Array.from({ length: 32 }, (_, index) => index + 11)
const body = new TextEncoder().encode("authenticated upload body")

const claimed = (): ClaimedInlineProtocolUpload => ({
  uploadId,
  lockToken: new Uint8Array(32),
  userId: 7,
  accountSessionId: 9,
  permanentAuthKeyId: new Uint8Array(8),
  temporaryAuthKeyId: new Uint8Array(8),
  fileName: "proof.txt",
  mimeType: "text/plain",
  byteCount: BigInt(body.length),
  sha256: createHash("sha256").update(body).digest(),
  kind: "document",
})

describe("Inline Protocol durable HTTP upload boundary", () => {
  test("accepts only the exact capability, metadata, length, and committed body hash", async () => {
    const released: ClaimedInlineProtocolUpload[] = []
    const completed: string[] = []
    const repository = {
      claim: async () => ({ kind: "claimed", upload: claimed() } as const),
      release: async (upload: ClaimedInlineProtocolUpload) => { released.push(upload) },
      complete: async (_upload: ClaimedInlineProtocolUpload, fileUniqueId: string) => {
        completed.push(fileUniqueId)
        return true
      },
    } as unknown as Pick<InlineProtocolUploadRepository, "create" | "claim" | "complete" | "release" | "finish">
    const received: string[] = []
    const receivedIps: Array<string | undefined> = []
    const operations = new InlineProtocolUploadOperations(repository, "https://api.inline.test", async (input, context) => {
      received.push(await input.file!.text())
      receivedIps.push(context.ip)
      return { fileUniqueId: "INDdurable" }
    })
    const url = `https://api.inline.test/v3/uploads/${Buffer.from(uploadId).toString("base64url")}`
    const response = await operations.handleHttp(new Request(url, {
      method: "PUT",
      headers: {
        authorization: `InlineUpload ${Buffer.from(capability).toString("base64url")}`,
        "content-type": "text/plain",
        "content-length": String(body.length),
        "x-forwarded-for": "198.51.100.200",
      },
      body,
    }), "203.0.113.10")
    expect(response?.status).toBe(204)
    expect(received).toEqual(["authenticated upload body"])
    expect(receivedIps).toEqual(["203.0.113.10"])
    expect(completed).toEqual(["INDdurable"])
    expect(released).toEqual([])
  })

  test("does not publish a body whose hash differs from the authenticated intent", async () => {
    let uploads = 0
    let releases = 0
    const repository = {
      claim: async () => ({ kind: "claimed", upload: claimed() } as const),
      release: async () => { releases += 1 },
      complete: async () => true,
    } as unknown as Pick<InlineProtocolUploadRepository, "create" | "claim" | "complete" | "release" | "finish">
    const operations = new InlineProtocolUploadOperations(repository, "https://api.inline.test", async () => {
      uploads += 1
      return { fileUniqueId: "never" }
    })
    const altered = new TextEncoder().encode("altered upload body......")
    expect(altered.length).toBe(body.length)
    const response = await operations.handleHttp(new Request(
      `https://api.inline.test/v3/uploads/${Buffer.from(uploadId).toString("base64url")}`,
      {
        method: "PUT",
        headers: {
          authorization: `InlineUpload ${Buffer.from(capability).toString("base64url")}`,
          "content-type": "text/plain",
          "content-length": String(altered.length),
        },
        body: altered,
      },
    ))
    expect(response?.status).toBe(400)
    expect(uploads).toBe(0)
    expect(releases).toBe(1)
  })
})
