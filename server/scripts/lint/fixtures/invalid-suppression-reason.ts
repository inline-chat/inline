import { Effect } from "effect"

// oxlint-disable-next-line inline-effect/no-effect-escape-hatch
export const program = Effect.orDie(Effect.fail("expected failure"))
