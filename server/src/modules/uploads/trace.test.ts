import { describe, expect, test } from "bun:test"
import { LogLevel } from "@in/server/utils/log"
import { uploadTraceLogLevel } from "./trace"

describe("upload trace opt-in", () => {
  test("leaves normal logging unchanged except for an explicit1 flag", () => {
    for (const value of [undefined, "", "0", "true", "yes", " 1 "]) {
      expect(uploadTraceLogLevel({ INLINE_UPLOAD_TRACE: value })).toBeUndefined()
    }
    expect(uploadTraceLogLevel({ INLINE_UPLOAD_TRACE: "1" })).toBe(LogLevel.DEBUG)
  })
})
