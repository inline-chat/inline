import * as EffectModule from "effect"

export const program = EffectModule.Effect.orDie(
  EffectModule.Effect.fail("expected failure"),
)
