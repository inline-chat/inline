import { describe, expect, test } from "bun:test"
import { Cause, Context, Effect, Exit, Schema } from "effect"
import { InvalidInputError, PositiveInt } from "../types"
import { decodeUnknown } from "./schema"

class DecodeDependency extends Context.Service<DecodeDependency, { readonly marker: string }>()(
  "inline/effect-server/test/DecodeDependency",
) {}

describe("decodeUnknown", () => {
  test("returns the decoded value", async () => {
    expect(Number(await Effect.runPromise(decodeUnknown(PositiveInt)(42)))).toBe(42)
  })

  test("maps parser failures to a safe typed error", async () => {
    const secretInput = "secret-value-that-must-not-leak"
    const exit = await Effect.runPromiseExit(decodeUnknown(PositiveInt, { field: "userId" })(secretInput))

    expect(Exit.isFailure(exit)).toBe(true)
    expect(String(exit)).not.toContain(secretInput)

    if (Exit.isFailure(exit)) {
      const failure = Cause.squash(exit.cause)
      expect(failure).toMatchObject({ _tag: "InvalidInputError", field: "userId" })
    }
  })

  test("retains schema service requirements in the helper signature", async () => {
    const schema = Schema.String.pipe(
      Schema.middlewareDecoding((effect) =>
        Effect.gen(function* () {
          yield* DecodeDependency
          return yield* effect
        }),
      ),
    )
    const decoded: Effect.Effect<string, InvalidInputError, DecodeDependency> = decodeUnknown(schema)("ok")

    expect(
      await Effect.runPromise(
        decoded.pipe(Effect.provideService(DecodeDependency, { marker: "available" })),
      ),
    ).toBe("ok")
  })
})
