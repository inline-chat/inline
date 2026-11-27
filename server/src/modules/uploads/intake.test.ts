import { describe, expect, test } from "bun:test"
import {
  UPLOAD_PIECE_GRANULARITY as G,
  UploadPartIntake,
  UploadPieceAssembler,
  isValidPiece,
} from "./intake"

const deferred = () => {
  let resolve!: () => void
  let reject!: (error: unknown) => void
  const promise = new Promise<void>((done, fail) => { resolve = done; reject = fail })
  return { promise, resolve, reject }
}

const bytes = (length: number, seed: number): Uint8Array =>
  Uint8Array.from({ length }, (_, index) => (index * 31 + seed) & 0xff)

describe("upload pieces", () => {
  test("accepts aligned pieces and the short piece that ends a part", () => {
    expect(isValidPiece(512 * 1024, 0, G)).toBe(true)
    expect(isValidPiece(512 * 1024, 31 * G, G)).toBe(true)
    expect(isValidPiece(512 * 1024, 0, 512 * 1024)).toBe(true)
    expect(isValidPiece(40_000, 2 * G, 40_000 - 2 * G)).toBe(true)
    expect(isValidPiece(512 * 1024, 1, G)).toBe(false)
    expect(isValidPiece(512 * 1024, 0, G - 1)).toBe(false)
    expect(isValidPiece(512 * 1024, 31 * G, 2 * G)).toBe(false)
    expect(isValidPiece(512 * 1024, 0, 0)).toBe(false)
    expect(isValidPiece(512 * 1024, -G, G)).toBe(false)
  })

  test("returns the whole part once every byte arrived, in any order, resends included", () => {
    const assembler = new UploadPieceAssembler()
    const part = bytes(3 * G + 100, 7)
    expect(assembler.add(1, 0, part.length, 2 * G, part.subarray(2 * G, 3 * G))).toBeUndefined()
    expect(assembler.add(1, 0, part.length, 0, part.subarray(0, 2 * G))).toBeUndefined()
    expect(assembler.add(1, 0, part.length, 2 * G, part.subarray(2 * G, 3 * G))).toBeUndefined()
    expect(assembler.bytes).toBe(part.length)
    const whole = assembler.add(1, 0, part.length, 3 * G, part.subarray(3 * G))
    expect(whole).toEqual(part)
    expect(assembler.bytes).toBe(0)
    expect(assembler.size).toBe(0)
  })

  test("keeps parts of different uploads and indices apart and drops one upload", () => {
    const assembler = new UploadPieceAssembler()
    assembler.add(1, 0, 2 * G, 0, bytes(G, 1))
    assembler.add(1, 1, 2 * G, 0, bytes(G, 2))
    assembler.add(2, 0, 2 * G, 0, bytes(G, 3))
    assembler.drop(1)
    expect(assembler.size).toBe(1)
    expect(assembler.add(2, 0, 2 * G, G, bytes(G, 4))?.subarray(0, G)).toEqual(bytes(G, 3))
  })

  test("evicts the least recently touched part to stay within its bound, and idle parts", () => {
    let now = 0
    const assembler = new UploadPieceAssembler(4 * G, 1_000, () => now)
    assembler.add(1, 0, 2 * G, 0, bytes(G, 1))
    assembler.add(1, 1, 2 * G, 0, bytes(G, 2))
    now = 10
    assembler.add(1, 0, 2 * G, G, bytes(G, 9)) // completes part 0
    assembler.add(1, 2, 2 * G, 0, bytes(G, 3))
    assembler.add(1, 3, 2 * G, 0, bytes(G, 4)) // over the bound: part 1 goes
    expect(assembler.bytes).toBe(4 * G)
    expect(assembler.add(1, 1, 2 * G, G, bytes(G, 5))).toBeUndefined() // starts over
    now = 5_000
    assembler.add(1, 9, 2 * G, 0, bytes(G, 6)) // idle parts are swept first
    expect(assembler.size).toBe(1)
  })
})

describe("upload part intake", () => {
  test("acknowledges before the write and lets finish wait for it", async () => {
    const intake = new UploadPartIntake()
    const write = deferred()
    let stored = false
    const accepted = await intake.accept(7, 0, 100, async () => { await write.promise; stored = true })
    expect(accepted).toEqual({ queued: true })
    expect(intake.isPending(7, 0)).toBe(true)
    expect(intake.pendingParts(7)).toEqual([0])
    expect(intake.pendingBytes).toBe(100)
    // A resend while the write runs is acknowledged without a second write.
    expect(await intake.accept(7, 0, 100, async () => { throw new Error("second write") })).toEqual({ queued: true })
    expect(await intake.settle(7, 10)).toBe(false)
    write.resolve()
    expect(await intake.settle(7, 1_000)).toBe(true)
    expect(stored).toBe(true)
    expect(intake.isPending(7, 0)).toBe(false)
    expect(intake.pendingBytes).toBe(0)
  })

  test("a failed write leaves the part unheld, so finish reports it missing", async () => {
    const intake = new UploadPartIntake()
    await intake.accept(7, 3, 10, async () => { throw new Error("storage write failed") })
    expect(await intake.settle(7, 1_000)).toBe(true)
    expect(intake.isPending(7, 3)).toBe(false)
    expect(intake.pendingParts(7)).toEqual([])
  })

  test("stores before the reply past the memory bounds", async () => {
    const intake = new UploadPartIntake({ maxPendingBytes: 150, maxPendingBytesPerUpload: 120 })
    const write = deferred()
    expect(await intake.accept(1, 0, 100, () => write.promise)).toEqual({ queued: true })
    // Per upload: 100 + 30 > 120.
    expect(await intake.accept(1, 1, 30, async () => "stored")).toEqual({ queued: false, value: "stored" })
    // Another upload fits its own bound but not the process bound: 100 + 60 > 150.
    expect(await intake.accept(2, 0, 60, async () => "stored")).toEqual({ queued: false, value: "stored" })
    expect(await intake.accept(2, 1, 40, async () => {})).toEqual({ queued: true })
    write.resolve()
    expect(await intake.drain(1_000)).toBe(true)
  })

  test("after a storage outage parts are stored before the reply, so clients see the 503", async () => {
    let now = 0
    const outage = new Error("storage unavailable")
    const intake = new UploadPartIntake({
      now: () => now,
      storageBackoffMs: 30_000,
      isStorageOutage: (error) => error === outage,
    })
    await intake.accept(1, 0, 10, async () => { throw outage })
    await intake.settle(1, 1_000)
    await expect(intake.accept(1, 0, 10, async () => { throw outage })).rejects.toBe(outage)
    now = 29_999
    expect(await intake.accept(1, 1, 10, async () => "stored")).toEqual({ queued: false, value: "stored" })
    now = 30_000
    expect(await intake.accept(1, 2, 10, async () => {})).toEqual({ queued: true })
  })

  test("runs at most `concurrency` writes at once, in arrival order", async () => {
    const intake = new UploadPartIntake({ concurrency: 2 })
    const writes = [deferred(), deferred(), deferred()]
    const started: number[] = []
    for (const [index, write] of writes.entries()) {
      await intake.accept(1, index, 1, async () => { started.push(index); await write.promise })
    }
    await Bun.sleep(1)
    expect(started).toEqual([0, 1])
    writes[1]!.resolve()
    await Bun.sleep(1)
    expect(started).toEqual([0, 1, 2])
    writes[0]!.resolve()
    writes[2]!.resolve()
    expect(await intake.drain(1_000)).toBe(true)
  })
})
