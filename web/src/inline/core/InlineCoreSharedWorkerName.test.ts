import { describe, expect, it } from "vitest"
import { INLINE_CORE_PROTOCOL_VERSION } from "./InlineCoreProtocol"
import {
  activeInlineCoreSharedWorkerName,
  replacementInlineCoreSharedWorkerName,
} from "./InlineCoreSharedWorkerName"

describe("Inline SharedWorker identity", () => {
  const stableName = `inline-core-v${INLINE_CORE_PROTOCOL_VERSION}`
  it("uses one protocol-versioned worker name for clean boot", () => {
    expect(activeInlineCoreSharedWorkerName()).toBe(stableName)
  })

  it("gives a bounded boot replacement a distinct owner name", () => {
    expect(replacementInlineCoreSharedWorkerName()).toMatch(
      new RegExp(`^${stableName}-replacement-`),
    )
    expect(replacementInlineCoreSharedWorkerName()).not.toBe(
      replacementInlineCoreSharedWorkerName(),
    )
  })
})
