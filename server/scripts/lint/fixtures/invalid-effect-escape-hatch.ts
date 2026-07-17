import { Effect as Fx } from "effect"
import { orDie as collapseFailure } from "effect/Effect"

export const memberEscapeHatch = Fx.orDie(Fx.fail("expected failure"))
export const namedEscapeHatch = collapseFailure(Fx.fail("expected failure"))
