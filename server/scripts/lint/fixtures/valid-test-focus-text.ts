import { test } from "bun:test"
// test.only in a comment is not a focused test.
const object = { only: () => "test.only" }
test("mentions test.only as data", () => { object.only() })
