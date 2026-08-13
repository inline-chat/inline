import { Cause } from "effect"
import { describe, expect, it } from "vitest"
import { effectCauseDiagnostic } from "./effectCauseDiagnostics"

describe("effectCauseDiagnostic", () => {
  it("uses the real error while redacting contact details", () => {
    const providerError = new Error(
      "Delivery failed for person@example.com at +1 (555) 555-0123",
    ) as Error & { code: string; providerPayload?: unknown }
    providerError.name = "ProviderUnavailable"
    providerError.code = "UNAVAILABLE"
    providerError.providerPayload = {
      recipient: "person@example.com",
      secret: "private",
    }

    const diagnostic = effectCauseDiagnostic(
      Cause.fail(providerError),
    )

    expect(diagnostic.error).toBeInstanceOf(Error)
    expect(diagnostic.error).not.toBe(providerError)
    expect(diagnostic.error.name).toBe("ProviderUnavailable")
    expect(diagnostic.error.message).toBe(
      "Delivery failed for <redacted> at <redacted>",
    )
    expect(diagnostic.metadata).toEqual({
      reasonCount: 1,
      reasons: [{
        kind: "Fail",
        errorType: "ProviderUnavailable",
        errorCode: "UNAVAILABLE",
      }],
    })
    expect("providerPayload" in diagnostic.error).toBe(false)
    expect(JSON.stringify(diagnostic)).not.toContain("person@example.com")
    expect(JSON.stringify(diagnostic)).not.toContain("private")
  })

  it("does not serialize arbitrary typed failure fields", () => {
    const diagnostic = effectCauseDiagnostic(Cause.fail({
      _tag: "ProviderFailure",
      email: "person@example.com",
      providerPayload: { secret: "private" },
      status: 503,
    }))

    expect(diagnostic.error.name).toBe("ProviderFailure")
    expect(diagnostic.error.message).toBe(
      "Effect Fail: ProviderFailure",
    )
    expect(diagnostic.metadata).toEqual({
      reasonCount: 1,
      reasons: [{
        kind: "Fail",
        errorType: "ProviderFailure",
        errorCode: 503,
      }],
    })
    expect(JSON.stringify(diagnostic)).not.toContain("person@example.com")
    expect(JSON.stringify(diagnostic)).not.toContain("private")
  })

  it("distinguishes defects and interruption-only causes", () => {
    const defect = effectCauseDiagnostic(
      Cause.die(new TypeError("provider exploded")),
    )
    const interruption = effectCauseDiagnostic(Cause.interrupt(42))

    expect(defect.error.name).toBe("TypeError")
    expect(defect.metadata.reasons).toEqual([{
      kind: "Die",
      errorType: "TypeError",
      errorCode: undefined,
    }])
    expect(interruption.error.name).toBe("EffectInterruptError")
    expect(interruption.metadata).toEqual({
      reasonCount: 1,
      reasons: [{ kind: "Interrupt" }],
    })
    expect(JSON.stringify(interruption)).not.toContain("42")
  })

  it("bounds reason metadata and redacts diagnostic codes", () => {
    const reasons = Array.from({ length: 10 }, (_, index) =>
      Cause.makeFailReason({
        _tag: `Failure${index}`,
        code: index === 0 ? "person@example.com" : index,
      }))
    const diagnostic = effectCauseDiagnostic(Cause.fromReasons(reasons))

    expect(diagnostic.metadata.reasonCount).toBe(10)
    expect(diagnostic.metadata.reasons).toHaveLength(8)
    expect(diagnostic.metadata.reasons[0]?.errorCode).toBe("<redacted>")
  })
})
