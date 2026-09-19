import { test as check } from "bun:test"
import { Effect } from "effect"
import { it } from "@effect/vitest"
import * as v from "vitest"
import { suite as group } from "vitest"
check.only("must fail lint", () => {})
it.effect.only("must fail lint", () => Effect.void)
v.describe["only"]("must fail lint", () => {})
group.only("must fail lint", () => {})
