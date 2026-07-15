import { expect, it, layer } from "@effect/vitest"
import { Context, Effect, Exit, Fiber, Layer, Ref, Schedule } from "effect"
import { TestClock } from "effect/testing"
import { decodeUnknown } from "../helpers"
import { InvalidInputError, PositiveInt, type PositiveInt as PositiveIntType } from "../types"

class Greeting extends Context.Service<Greeting, { readonly value: string }>()("inline/testing/Greeting") {}

const GreetingTest = Layer.succeed(Greeting, { value: "hello" })

layer(GreetingTest)("Effect migration test foundation", (it) => {
  it.effect("provides test services through a Layer", () =>
    Effect.gen(function* () {
      const greeting = yield* Greeting
      expect(greeting.value).toBe("hello")
    }),
  )
})

it.effect("controls retry time with TestClock", () =>
  Effect.gen(function* () {
    const attempts = yield* Ref.make(0)
    const operation = Effect.gen(function* () {
      const attempt = yield* Ref.updateAndGet(attempts, (value) => value + 1)
      return attempt < 3 ? yield* Effect.fail("retry") : attempt
    })
    const policy = Schedule.addDelay(Schedule.recurs(2), () => Effect.succeed("1 second"))
    const fiber = yield* operation.pipe(Effect.retry(policy), Effect.forkChild)

    yield* TestClock.adjust("2 seconds")

    expect(yield* Fiber.join(fiber)).toBe(3)
  }),
)

it.effect("runs finalizers when a scope closes", () =>
  Effect.gen(function* () {
    const released = yield* Ref.make(false)

    yield* Effect.scoped(
      Effect.acquireRelease(Effect.succeed("resource"), () => Ref.set(released, true)),
    )

    expect(yield* Ref.get(released)).toBe(true)
  }),
)

it.effect("interrupts child fibers and runs interruption cleanup", () =>
  Effect.gen(function* () {
    const interrupted = yield* Ref.make(false)
    const fiber = yield* Effect.never.pipe(
      Effect.onInterrupt(() => Ref.set(interrupted, true)),
      Effect.forkChild,
    )

    yield* Effect.yieldNow
    yield* Fiber.interrupt(fiber)

    expect(yield* Ref.get(interrupted)).toBe(true)
  }),
)

it.effect("keeps schema failures typed and redacted", () =>
  Effect.gen(function* () {
    const decoded: Effect.Effect<PositiveIntType, InvalidInputError> = decodeUnknown(PositiveInt)(1)
    const failure = yield* Effect.exit(decodeUnknown(PositiveInt)("sensitive-raw-input"))

    expect(yield* decoded).toBe(1)
    expect(Exit.isFailure(failure)).toBe(true)
    expect(String(failure)).not.toContain("sensitive-raw-input")
  }),
)
