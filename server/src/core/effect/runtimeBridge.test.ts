import { describe, expect, it } from "@effect/vitest"
import { Cause, Context, Effect, Exit, Layer } from "effect"
import { makeRuntimeBridge } from "./runtimeBridge"

class Probe extends Context.Service<Probe, { readonly acquisition: number }>()(
  "@inline/server/core/test/Probe",
) {}

describe("RuntimeBridge", () => {
  it("memoizes its Layer and releases process resources on disposal", async () => {
    let acquisitions = 0
    let releases = 0

    const ProbeLive = Layer.effect(
      Probe,
      Effect.acquireRelease(
        Effect.sync(() => ({ acquisition: ++acquisitions })),
        () => Effect.sync(() => {
          releases += 1
        }),
      ),
    )
    const bridge = makeRuntimeBridge(ProbeLive)

    try {
      const first = await bridge.runPromiseExit(Probe.use((probe) => Effect.succeed(probe.acquisition)))
      const second = await bridge.runPromiseExit(Probe.use((probe) => Effect.succeed(probe.acquisition)))

      expect(Exit.isSuccess(first) && first.value).toBe(1)
      expect(Exit.isSuccess(second) && second.value).toBe(1)
      expect(acquisitions).toBe(1)
      expect(releases).toBe(0)
    } finally {
      await bridge.dispose()
    }

    expect(releases).toBe(1)
  })

  it("returns expected failures in Exit instead of rejecting the Promise", async () => {
    const bridge = makeRuntimeBridge(Layer.empty)
    const failure = { _tag: "ExpectedFailure" as const }

    try {
      const exit = await bridge.runPromiseExit(Effect.fail(failure))

      expect(Exit.isFailure(exit)).toBe(true)
      if (Exit.isFailure(exit)) {
        expect(Cause.squash(exit.cause)).toEqual(failure)
      }
    } finally {
      await bridge.dispose()
    }
  })

  it("returns defects in Exit instead of rejecting the Promise", async () => {
    const bridge = makeRuntimeBridge(Layer.empty)

    try {
      const exit = await bridge.runPromiseExit(Effect.die("unexpected defect"))

      expect(Exit.isFailure(exit)).toBe(true)
      if (Exit.isFailure(exit)) {
        expect(Cause.hasDies(exit.cause)).toBe(true)
      }
    } finally {
      await bridge.dispose()
    }
  })
})
