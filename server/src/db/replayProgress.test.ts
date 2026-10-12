import { expect, test } from "bun:test"
import { ReplayProgress, type ReplayProgressOperation } from "./replayProgress"

test("distinguishes advancing replay from repeated work without exporting coordinates", () => {
  const rows: { operation: ReplayProgressOperation; workItems: number }[] = []
  const progress = new ReplayProgress((operation, workItems) => rows.push({ operation, workItems }))
  progress.start("private-session-bucket", "user", "macos", 10)(100)
  const earlier = progress.start("private-session-bucket", "user", "macos", 110)
  progress.start("private-session-bucket", "user", "macos", 110)(0)
  earlier(100)
  progress.start("private-session-bucket", "user", "macos", 10)(100)
  progress.start("another-bucket", "chat", "untrusted value", 0)(4)
  expect(rows.map((row) => row.operation)).toEqual([
    "replay.user.macos.first", "replay.user.macos.repeat", "replay.user.macos.advance",
    "replay.user.macos.rewind", "replay.chat.unknown.first",
  ])
  expect(rows[1]?.workItems).toBe(0)
  expect(JSON.stringify(rows)).not.toContain("private-session-bucket")
})

test("expires idle cursors and evicts the oldest cursor at capacity", () => {
  let now = 0
  const operations: ReplayProgressOperation[] = []
  const progress = new ReplayProgress((operation) => operations.push(operation), () => now, 2, 100)
  for (const identity of ["a", "b", "c", "a"]) progress.start(identity, "user", "cli", 1)(1)
  progress.start("a", "user", "cli", 1)(1)
  now = 100
  progress.start("a", "user", "cli", 1)(1)
  expect(operations.map((operation) => operation.split(".").at(-1))).toEqual([
    "first", "first", "first", "first", "repeat", "first",
  ])
})
