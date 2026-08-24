import { describe, expect, spyOn, test } from "bun:test"
import {
  FinishUploadResult,
  GetUploadStateResult,
  SaveUploadPartInput,
  UploadFailure_Code,
} from "../src/core"
import {
  NativeUploadClient,
  UploadKind,
  UploadStatus,
  uploadByteSource,
  type NativeUploadRpcTransport,
} from "../src/uploads"

class MemoryUploadTransport implements NativeUploadRpcTransport {
  readonly accepted = new Map<string, Set<number>>()
  readonly partCalls: string[] = []
  readonly canceled = new Set<string>()
  active = 0
  maxActive = 0
  failAfterAcceptOnce = false
  failFinishOnce = false
  acceptedPartsOverride: number[] | undefined
  stateResponses: GetUploadStateResult[] = []
  finishResponses: FinishUploadResult[] = []
  stateCalls = 0
  finishCalls = 0
  partSize = 4
  maxPartBytes = 0

  async create(input: { clientUploadId: Uint8Array; byteCount: bigint }) {
    const id = Buffer.from(input.clientUploadId).toString("hex")
    this.accepted.set(id, new Set())
    return {
      uploadId: input.clientUploadId,
      partSize: this.partSize,
      partCount: Math.ceil(Number(input.byteCount) / this.partSize),
      expiresAt: 1_900_000_000n,
      acceptedParts: this.acceptedPartsOverride ?? [],
    }
  }

  async savePart(input: { uploadId: Uint8Array; partIndex: number; data: Uint8Array }) {
    const id = Buffer.from(input.uploadId).toString("hex")
    this.active += 1
    this.maxActive = Math.max(this.maxActive, this.active)
    this.maxPartBytes = Math.max(this.maxPartBytes, input.data.length)
    this.partCalls.push(`${id}:${input.partIndex}`)
    await new Promise((resolve) => setTimeout(resolve, 1))
    this.accepted.get(id)!.add(input.partIndex)
    this.active -= 1
    if (this.failAfterAcceptOnce) {
      this.failAfterAcceptOnce = false
      throw new Error("response lost")
    }
    return { alreadyPresent: false }
  }

  async state(input: { uploadId: Uint8Array }) {
    this.stateCalls += 1
    const response = this.stateResponses.shift()
    if (response) return response
    const id = Buffer.from(input.uploadId).toString("hex")
    return {
      status: UploadStatus.UPLOADING,
      acceptedParts: [...this.accepted.get(id)!],
    }
  }

  async finish(input: { uploadId: Uint8Array }) {
    this.finishCalls += 1
    if (this.failFinishOnce) {
      this.failFinishOnce = false
      throw new Error("finish response lost")
    }
    const response = this.finishResponses.shift()
    if (response) return response
    const id = Buffer.from(input.uploadId).toString("hex")
    return {
      state: {
        oneofKind: "complete" as const,
        complete: { fileUniqueId: `file-${id}`, media: { oneofKind: undefined as const } },
      },
    }
  }

  async cancel(input: { uploadId: Uint8Array }) {
    this.canceled.add(Buffer.from(input.uploadId).toString("hex"))
    return { canceled: true, alreadyTerminal: false }
  }
}

const input = (seed: number) => ({
  source: uploadByteSource(Uint8Array.from({ length: 12 }, (_, index) => seed + index)),
  fileName: `file-${seed}.bin`,
  mimeType: "application/octet-stream",
  kind: UploadKind.DOCUMENT,
  clientUploadId: Uint8Array.from({ length: 16 }, () => seed),
})

const virtualInput = (seed: number, byteCount: number) => ({
  source: {
    byteCount,
    read: async (_offset: number, length: number) => new Uint8Array(length).fill(seed),
  },
  fileName: `virtual-${seed}.bin`,
  mimeType: "application/octet-stream",
  kind: UploadKind.DOCUMENT,
  clientUploadId: Uint8Array.from({ length: 16 }, () => seed),
})

describe("native upload coordinator", () => {
  test("bounds authenticated processing retry hints", async () => {
    const transport = new MemoryUploadTransport()
    transport.partSize = 12
    transport.finishResponses.push(
      ...[0, 2.9, 4_294_967_295, Number.NaN, Number.POSITIVE_INFINITY, Number.NEGATIVE_INFINITY]
        .map((retryAfterSeconds) => ({
          state: { oneofKind: "processing" as const, processing: { retryAfterSeconds } },
        })),
    )
    const delays: number[] = []
    const timeoutSpy = spyOn(globalThis, "setTimeout").mockImplementation((callback, milliseconds) => {
      delays.push(milliseconds ?? 0)
      if (typeof callback === "function") callback()
      return 0 as unknown as ReturnType<typeof setTimeout>
    })

    try {
      await new NativeUploadClient(transport).upload(input(20))
    } finally {
      timeoutSpy.mockRestore()
    }

    expect(delays).toEqual([1, 1_000, 2_000, 30_000, 1_000, 30_000, 1_000])
  })

  test("cancellation interrupts a bounded processing wait", async () => {
    const transport = new MemoryUploadTransport()
    transport.finishResponses.push({
      state: { oneofKind: "processing", processing: { retryAfterSeconds: 4_294_967_295 } },
    })
    const controller = new AbortController()
    const upload = new NativeUploadClient(transport).upload({ ...input(21), signal: controller.signal })

    while (transport.finishCalls === 0) await new Promise((resolve) => setTimeout(resolve, 1))
    controller.abort()

    await expect(upload).rejects.toThrow("Upload was canceled")
    expect(transport.canceled).toHaveLength(1)
  })

  test("bounds global work and fairly completes ten concurrent files", async () => {
    const transport = new MemoryUploadTransport()
    const uploads = new NativeUploadClient(transport)
    const results = await Promise.all(Array.from({ length: 10 }, (_, index) => uploads.upload(input(index + 1))))

    expect(results).toHaveLength(10)
    expect(transport.maxActive).toBeLessThanOrEqual(3)
    expect(transport.partCalls).toHaveLength(30)
    for (const accepted of transport.accepted.values()) expect([...accepted].sort()).toEqual([0, 1, 2])
  })

  test("reconciles a part committed before its response was lost", async () => {
    const transport = new MemoryUploadTransport()
    transport.failAfterAcceptOnce = true
    const progress: number[] = []
    const uploads = new NativeUploadClient(transport)

    const result = await uploads.upload({
      ...input(42),
      onProgress: ({ acceptedBytes }) => progress.push(acceptedBytes),
    })

    expect(result.fileUniqueId).toContain("file-")
    expect(progress.at(-1)).toBe(12)
    expect(transport.partCalls).toHaveLength(3)
  })

  test("reconciles a finish whose response was lost after complete publication", async () => {
    const transport = new MemoryUploadTransport()
    transport.failFinishOnce = true
    const uploadId = Buffer.from(new Uint8Array(16).fill(42)).toString("hex")
    transport.stateResponses.push({
      status: UploadStatus.COMPLETE,
      acceptedParts: [0, 1, 2],
      complete: { fileUniqueId: `file-${uploadId}`, media: { oneofKind: undefined } },
    })

    await expect(new NativeUploadClient(transport).upload(input(42))).resolves.toEqual({
      fileUniqueId: `file-${uploadId}`,
      media: { oneofKind: undefined },
    })
    expect(transport.finishCalls).toBe(1)
    expect(transport.stateCalls).toBe(1)
  })

  test("continues the same upload when a lost finish response is still processing", async () => {
    const transport = new MemoryUploadTransport()
    transport.failFinishOnce = true
    const uploadId = Buffer.from(new Uint8Array(16).fill(43)).toString("hex")
    transport.stateResponses.push({ status: UploadStatus.PROCESSING, acceptedParts: [0, 1, 2] })

    await expect(new NativeUploadClient(transport).upload(input(43))).resolves.toEqual({
      fileUniqueId: `file-${uploadId}`,
      media: { oneofKind: undefined },
    })
    expect(transport.finishCalls).toBe(2)
    expect(transport.stateCalls).toBe(1)
  })

  test("reconciles missing parts reported after a lost finish response", async () => {
    const transport = new MemoryUploadTransport()
    transport.failFinishOnce = true
    const uploadId = Buffer.from(new Uint8Array(16).fill(45)).toString("hex")
    transport.stateResponses.push({ status: UploadStatus.UPLOADING, acceptedParts: [0] })

    await expect(new NativeUploadClient(transport).upload(input(45))).resolves.toEqual({
      fileUniqueId: `file-${uploadId}`,
      media: { oneofKind: undefined },
    })
    expect(transport.finishCalls).toBe(2)
    expect(transport.stateCalls).toBe(1)
    expect(transport.partCalls).toHaveLength(5)
  })

  test("preserves a terminal failure discovered while reconciling finish", async () => {
    const transport = new MemoryUploadTransport()
    transport.failFinishOnce = true
    transport.stateResponses.push({
      status: UploadStatus.FAILED,
      acceptedParts: [0, 1, 2],
      failure: { code: UploadFailure_Code.UPLOAD_FAILURE_INTEGRITY, retryable: false },
    })

    await expect(new NativeUploadClient(transport).upload(input(44)))
      .rejects.toThrow("Upload finalization failed")
    expect(transport.finishCalls).toBe(1)
    expect(transport.stateCalls).toBe(1)
  })

  test("rejects accepted-part indices outside negotiated geometry", async () => {
    const transport = new MemoryUploadTransport()
    transport.acceptedPartsOverride = [3]
    await expect(new NativeUploadClient(transport).upload(input(9)))
      .rejects.toThrow("invalid upload geometry")
  })

  test("keeps production-sized single and concurrent uploads bounded", async () => {
    const mebibyte = 1_024 * 1_024
    const transport = new MemoryUploadTransport()
    transport.partSize = 512 * 1_024
    const uploads = new NativeUploadClient(transport)

    await uploads.upload(virtualInput(21, 100 * mebibyte))
    await Promise.all(Array.from({ length: 10 }, (_, index) =>
      uploads.upload(virtualInput(index + 31, 10 * mebibyte))))

    expect(transport.maxPartBytes).toBe(512 * 1_024)
    expect(transport.maxActive).toBeLessThanOrEqual(3)
    expect(transport.partCalls).toHaveLength(400)
  }, 30_000)
})

describe("native upload wire semantics", () => {
  test("round-trips every finish state and a maximum-sized part", () => {
    const states: FinishUploadResult[] = [
      { state: { oneofKind: "missing", missing: { partIndices: [0, 4, 999] } } },
      { state: { oneofKind: "processing", processing: { retryAfterSeconds: 2 } } },
      {
        state: {
          oneofKind: "complete",
          complete: { fileUniqueId: "INDwire", media: { oneofKind: undefined } },
        },
      },
      {
        state: {
          oneofKind: "failed",
          failed: { code: UploadFailure_Code.UPLOAD_FAILURE_INTEGRITY, retryable: false },
        },
      },
    ]
    for (const state of states) {
      expect(FinishUploadResult.fromBinary(FinishUploadResult.toBinary(state))).toEqual(state)
    }

    const part = {
      uploadId: new Uint8Array(16).fill(7),
      partIndex: 999,
      data: new Uint8Array(512 * 1_024).fill(0xa5),
    }
    expect(SaveUploadPartInput.fromBinary(SaveUploadPartInput.toBinary(part))).toEqual(part)

    const uploadState = {
      status: UploadStatus.FAILED,
      acceptedParts: [0, 2],
      failure: { code: UploadFailure_Code.UPLOAD_FAILURE_STORAGE, retryable: true },
    }
    expect(GetUploadStateResult.fromBinary(GetUploadStateResult.toBinary(uploadState)))
      .toEqual(uploadState)
  })
})
