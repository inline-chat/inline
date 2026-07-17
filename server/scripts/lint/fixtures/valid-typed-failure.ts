import { Effect } from "effect"

const customApi = {
  orDie: (value: string) => value,
}

export const typedFailure = Effect.fail("expected failure")
export const unrelatedProperty = customApi.orDie("allowed")
