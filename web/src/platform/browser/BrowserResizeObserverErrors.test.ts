import { describe, expect, it } from "vitest"
import { isResizeObserverLoopError } from "./BrowserResizeObserverErrors"

describe("isResizeObserverLoopError", () => {
  it("matches only the browser ResizeObserver delivery warnings", () => {
    expect(
      isResizeObserverLoopError(
        "ResizeObserver loop completed with undelivered notifications.",
      ),
    ).toBe(true)
    expect(
      isResizeObserverLoopError("ResizeObserver loop limit exceeded"),
    ).toBe(true)
    expect(isResizeObserverLoopError("ResizeObserver failed"))
      .toBe(false)
  })
})
