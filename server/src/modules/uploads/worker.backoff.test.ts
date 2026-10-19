import { expect, test } from "bun:test"
import type { InlineUploadRepository } from "@in/server/db/models/inlineUploads"
import type { MediaUploadFinalizer } from "./finalizer"
import type { MultipartObjectStore } from "./multipartStore"
import type { UploadPartStore } from "./partStore"
import { NativeUploadWorker } from "./worker"

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms))

test("claim polls back off while idle and a wake restores the base interval", async () => {
  let claims = 0
  const repository = {
    claimProcessing: async () => { claims += 1; return undefined },
    listExpired: async () => [],
    getStorageWork: async () => undefined,
  } as unknown as InlineUploadRepository
  const worker = new NativeUploadWorker(
    repository,
    {} as UploadPartStore,
    {} as MultipartObjectStore,
    {} as MediaUploadFinalizer,
    { pollIntervalMs: 10, maximumIdleIntervalMs: 160 },
  )
  worker.start()
  try {
    // Thirty base intervals at 10 ms would be ~30 claims without backoff;
    // doubling gaps (1, 2, 4, 8, 16 ticks) leave far fewer.
    await sleep(300)
    expect(claims).toBeGreaterThanOrEqual(3)
    expect(claims).toBeLessThanOrEqual(10)
    expect(worker.idleMultiplier).toBeGreaterThanOrEqual(8)

    worker.wake(1)
    expect(worker.idleMultiplier).toBe(1)
  } finally {
    await worker.stop()
  }
})
