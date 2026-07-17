/* oxlint-disable inline-effect/no-effect-escape-hatch -- boundary: migration module */
import { Effect } from "effect"

export const program = Effect.orDie(Effect.fail("expected failure"))
