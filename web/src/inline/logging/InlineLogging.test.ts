import { beforeEach, describe, expect, it, vi } from "vitest"
import type { LogLevel } from "@inline/log"
import {
  inlineLog,
  inlineLogBuffer,
  retainInlineGlobalLogging,
} from "./InlineLogging"

describe("InlineLogging", () => {
  beforeEach(() => {
    inlineLogBuffer.clear()
    inlineLog.setLevel("info")
  })

  it("exposes non-enumerable sanitized live diagnostics", () => {
    const release = retainInlineGlobalLogging()

    expect(window.__inlineDiagnostics).toBeDefined()
    expect(Object.keys(window)).not.toContain("__inlineDiagnostics")
    expect(window.__inlineDiagnostics?.getLevel()).toBe("info")
    window.__inlineDiagnostics?.setLevel("debug")
    expect(inlineLog.getLevel()).toBe("debug")
    expect(() => window.__inlineDiagnostics?.setLevel("verbose" as LogLevel))
      .toThrow(RangeError)

    release()
  })

  it("retains global listeners until the last owner releases them", () => {
    const removeEventListener = vi.spyOn(window, "removeEventListener")
    const releaseFirst = retainInlineGlobalLogging()
    const releaseSecond = retainInlineGlobalLogging()
    inlineLogBuffer.clear()
    const dispatchHandledError = (message: string) => {
      const event = new ErrorEvent("error", {
        message,
        error: new Error(message),
      })
      event.preventDefault()
      window.dispatchEvent(event)
    }

    dispatchHandledError("first failure")
    releaseFirst()
    expect(removeEventListener).not.toHaveBeenCalledWith(
      "error",
      expect.any(Function),
    )
    dispatchHandledError("second failure")
    releaseSecond()
    expect(removeEventListener).toHaveBeenCalledWith(
      "error",
      expect.any(Function),
    )

    expect(inlineLogBuffer.snapshot().map((record) => record.event)).toEqual([
      "runtime.window.error",
      "runtime.window.error",
    ])
    removeEventListener.mockRestore()
  })

  it("keeps benign ResizeObserver delivery warnings out of diagnostics", () => {
    const release = retainInlineGlobalLogging()
    inlineLogBuffer.clear()

    window.dispatchEvent(new ErrorEvent("error", {
      message: "ResizeObserver loop limit exceeded",
    }))

    expect(inlineLogBuffer.snapshot()).toEqual([])
    release()
  })
})
