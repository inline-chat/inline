import { describe, expect, test } from "bun:test"
import { Schema } from "effect"
import {
  ConflictError,
  ForbiddenError,
  InvalidInputError,
  NotFoundError,
  UnauthorizedError,
} from "./errors"

describe("Effect server leaf errors", () => {
  test("errors are tagged, yieldable schema classes", () => {
    expect(new InvalidInputError({ field: "spaceId" })).toMatchObject({
      _tag: "InvalidInputError",
      field: "spaceId",
    })
    expect(new UnauthorizedError()).toMatchObject({ _tag: "UnauthorizedError" })
    expect(new ForbiddenError()).toMatchObject({ _tag: "ForbiddenError" })
    expect(new NotFoundError({ resource: "space", identifier: "42" })).toMatchObject({
      _tag: "NotFoundError",
      resource: "space",
      identifier: "42",
    })
    expect(new ConflictError({ resource: "username" })).toMatchObject({
      _tag: "ConflictError",
      resource: "username",
    })
  })

  test("errors encode without hidden causes or raw input", () => {
    const encoded = Schema.encodeSync(NotFoundError)(new NotFoundError({ resource: "space", identifier: "42" }))

    expect(encoded).toEqual({ _tag: "NotFoundError", resource: "space", identifier: "42" })
    expect(encoded).not.toHaveProperty("cause")
    expect(encoded).not.toHaveProperty("input")
  })
})
