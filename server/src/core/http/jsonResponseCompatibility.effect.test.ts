import { describe, expect, it } from "@effect/vitest"
import {
  omitUndefinedObjectProperties,
} from "./jsonResponseCompatibility"

describe("JSON response compatibility", () => {
  it("omits only undefined plain-object properties recursively", () => {
    const date = new Date("2026-07-20T00:00:00Z")
    const result = omitUndefinedObjectProperties({
      omitted: undefined,
      nullable: null,
      date,
      bigint: 42n,
      nested: {
        omitted: undefined,
        kept: "value",
      },
      array: [
        {
          omitted: undefined,
          kept: 7,
        },
        undefined,
      ],
    })

    expect(result).toEqual({
      nullable: null,
      date,
      bigint: 42n,
      nested: {
        kept: "value",
      },
      array: [
        {
          kept: 7,
        },
        undefined,
      ],
    })
  })
})
