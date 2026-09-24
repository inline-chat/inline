import {
  describe,
  expect,
  test,
} from "bun:test"
import {
  parseServerProcessRole,
} from "./processRole"

describe("server process role", () => {
  test("defaults local execution to all workers", () => {
    expect(parseServerProcessRole(undefined, false)).toBe("all")
  })

  test("requires an explicit production role", () => {
    expect(() => parseServerProcessRole(undefined, true)).toThrow(
      "INLINE_PROCESS_ROLE must be explicitly set",
    )
    expect(() => parseServerProcessRole("worker", true)).toThrow(
      "INLINE_PROCESS_ROLE must be api or all",
    )
  })

  test("distinguishes dark API and normal worker ownership", () => {
    expect(parseServerProcessRole("api", true)).toBe("api")
    expect(parseServerProcessRole("all", true)).toBe("all")
  })
})
