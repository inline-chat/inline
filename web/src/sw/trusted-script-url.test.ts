import { describe, expect, it } from "vitest"
import {
  SCRIPT_URL_POLICY_NAME,
  UntrustedScriptUrlError,
  trustedScriptUrl,
  type TrustedTypesLike,
} from "./trusted-script-url"

/** Trusted Types as an enforcing browser exposes them, with a CSP allow-list of policy names. */
const fakeTrustedTypes = (allowed: readonly string[]) => {
  const created: string[] = []
  const factory: TrustedTypesLike = {
    createPolicy(name, rules) {
      if (!allowed.includes(name) || created.includes(name)) throw new TypeError(`Policy ${name} disallowed`)
      created.push(name)
      return { createScriptURL: (input) => ({ trusted: rules.createScriptURL(input), toString: () => rules.createScriptURL(input) }) }
    },
  }
  return { factory, created }
}

const baseUrl = "https://app.inline.chat/c/1"

describe("trustedScriptUrl", () => {
  it("mints a TrustedScriptURL for a same-origin script, creating the policy once", () => {
    const { factory, created } = fakeTrustedTypes(["default", SCRIPT_URL_POLICY_NAME])
    const first = trustedScriptUrl("/sw.js", { trustedTypes: factory, baseUrl })
    const second = trustedScriptUrl("/assets/core.worker-x.js", { trustedTypes: factory, baseUrl })
    expect(first).toMatchObject({ trusted: "https://app.inline.chat/sw.js" })
    expect(second).toMatchObject({ trusted: "https://app.inline.chat/assets/core.worker-x.js" })
    expect(created).toEqual([SCRIPT_URL_POLICY_NAME])
  })

  it("refuses a cross-origin script with or without Trusted Types", () => {
    const { factory } = fakeTrustedTypes([SCRIPT_URL_POLICY_NAME])
    expect(() => trustedScriptUrl("https://evil.example/sw.js", { trustedTypes: factory, baseUrl })).toThrow(
      UntrustedScriptUrlError,
    )
    expect(() => trustedScriptUrl("//evil.example/sw.js", { trustedTypes: undefined, baseUrl })).toThrow(
      UntrustedScriptUrlError,
    )
  })

  it.each([
    ["a same-origin blob: URL", "blob:https://app.inline.chat/2f1d7c4e-0000-4000-8000-000000000000"],
    ["a data: URL", "data:text/javascript,postMessage(1)"],
    ["a javascript: URL", "javascript:postMessage(1)"],
    ["a protocol-relative URL", "//evil.example/sw.js"],
    ["a backslash URL", "\\\\evil.example/sw.js"],
    ["a mixed-slash URL", "/\\evil.example/sw.js"],
    ["a URL with credentials", "https://user:pass@app.inline.chat/sw.js"],
    ["a URL with a user name", "https://user@app.inline.chat/sw.js"],
    ["another port", "https://app.inline.chat:8443/sw.js"],
    ["another scheme on the same host", "http://app.inline.chat/sw.js"],
  ])("refuses %s, with or without Trusted Types", (_label, input) => {
    const { factory } = fakeTrustedTypes([SCRIPT_URL_POLICY_NAME])
    expect(() => trustedScriptUrl(input, { trustedTypes: factory, baseUrl })).toThrow(UntrustedScriptUrlError)
    expect(() => trustedScriptUrl(input, { trustedTypes: undefined, baseUrl })).toThrow(UntrustedScriptUrlError)
  })

  it("accepts same-origin http in development", () => {
    expect(trustedScriptUrl("/sw.js", { trustedTypes: undefined, baseUrl: "http://localhost:8001/" })).toBe(
      "http://localhost:8001/sw.js",
    )
  })

  it("returns the checked string where Trusted Types do not exist", () => {
    expect(trustedScriptUrl("/sw.js", { trustedTypes: undefined, baseUrl })).toBe("https://app.inline.chat/sw.js")
  })

  it("falls back to the string when the content policy does not list the policy name", () => {
    const { factory, created } = fakeTrustedTypes(["default"])
    expect(trustedScriptUrl("/sw.js", { trustedTypes: factory, baseUrl })).toBe("https://app.inline.chat/sw.js")
    expect(created).toEqual([])
  })
})
