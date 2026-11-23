import { describe, expect, test } from "bun:test"
import { parseDataTaskArgs } from "./data-task"

describe("data-task arguments", () => {
  test("inspection and the automatic pass need nothing else", () => {
    expect(parseDataTaskArgs(["plan", "t", "--items"])).toMatchObject({ command: "plan", taskId: "t", items: true })
    expect(parseDataTaskArgs(["list"])).toMatchObject({ command: "list" })
    expect(parseDataTaskArgs(["run"])).toMatchObject({ command: "run" })
  })

  test("there is no manual apply; revert needs the database name and a backup", () => {
    expect(() => parseDataTaskArgs(["apply", "t"])).toThrow("Unknown command")
    expect(() => parseDataTaskArgs(["revert", "t", "--backup-verified"])).toThrow("--database")
    expect(() => parseDataTaskArgs(["revert", "t", "--database", "prod"])).toThrow("--backup-verified")
    expect(parseDataTaskArgs(["revert", "t", "--database", "prod", "--backup-verified", "--key", "a", "--key", "b"]))
      .toMatchObject({ keys: ["a", "b"] })
  })

  test("rejects unknown, repeated or misplaced flags", () => {
    expect(() => parseDataTaskArgs(["plan", "t", "--apply"])).toThrow()
    expect(() => parseDataTaskArgs(["plan", "--items"])).toThrow("task")
    expect(() => parseDataTaskArgs(["run", "--items"])).toThrow()
    expect(() => parseDataTaskArgs(["revert", "t", "--database", "a", "--database", "b"])).toThrow()
  })
})
