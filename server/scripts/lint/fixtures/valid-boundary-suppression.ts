import { Effect } from "effect"

// oxlint-disable-next-line inline-effect/no-effect-escape-hatch -- boundary: startup cannot continue without this required layer
export const program = Effect.orDie(Effect.fail("startup failed"))
