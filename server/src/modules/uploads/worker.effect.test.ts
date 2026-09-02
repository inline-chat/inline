import { describe, expect, it } from "@effect/vitest"
import { Effect, Layer } from "effect"
import { ErrorReporter } from "../../core/errors/errorReporter"
import { ProcessServiceStartFailure } from "../monitoring/ownedProcess.effect"
import type { NativeUploadWorker } from "./worker"
import {
  NativeUploadProcess,
  makeCurrentNativeUploadAdapter,
  makeNativeUploadProcessLayer,
} from "./worker.effect"

describe("Native upload process Layer", () => {
  it.effect("defers start and awaits the acquired worker during release", () =>
    Effect.gen(function* () {
      const events: string[] = []
      const worker = {} as NativeUploadWorker
      const layer = makeNativeUploadProcessLayer({
        start: () => { events.push("start"); return worker },
        stop: async (owned) => {
          expect(owned).toBe(worker)
          await Promise.resolve()
          events.push("stop")
        },
      }).pipe(Layer.provide(ErrorReporter.Noop))

      yield* NativeUploadProcess.use((process) => Effect.gen(function* () {
        expect(events).toEqual([])
        expect(yield* process.start).toBe(worker)
      })).pipe(Effect.provide(layer))

      expect(events).toEqual(["start", "stop"])
    }),
  )

  it("starts and stops the same compatibility worker", async () => {
    const events: string[] = []
    const worker = {} as NativeUploadWorker
    const adapter = makeCurrentNativeUploadAdapter(async () => ({
      acquireNativeUploadWorker: () => {
        events.push("start")
        return {
          worker,
          release: async () => { events.push("stop") },
        }
      },
    }))

    const acquired = await adapter.start()
    await adapter.stop(acquired)

    expect(acquired).toBe(worker)
    expect(events).toEqual(["start", "stop"])
  })

  it("surfaces a duplicate process owner as a typed start failure", async () => {
    const worker = {} as NativeUploadWorker
    let owned = false
    const load = async () => ({
      acquireNativeUploadWorker: () => {
        if (owned) throw new Error("already owned")
        owned = true
        return {
          worker,
          release: async () => { owned = false },
        }
      },
    })
    const first = makeCurrentNativeUploadAdapter(load)
    const second = makeCurrentNativeUploadAdapter(load)
    const secondLayer = makeNativeUploadProcessLayer(second).pipe(Layer.provide(ErrorReporter.Noop))

    const firstOwned = await first.start()
    try {
      const failure = await Effect.runPromise(Effect.flip(
        NativeUploadProcess.use((process) => process.start).pipe(Effect.provide(secondLayer)),
      ))
      expect(failure).toBeInstanceOf(ProcessServiceStartFailure)
      expect(failure.service).toBe("native-upload")
    } finally {
      await first.stop(firstOwned)
    }
  })
})
