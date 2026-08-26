import { beforeEach, describe, expect, test } from "bun:test"
import {
  agentSessionHash,
  agentSourceHash,
  decryptAgentSourceRefs,
  encryptAgentSourceRefs,
} from "./crypto"

describe("agent session reference crypto", () => {
  beforeEach(() => {
    process.env["ENCRYPTION_KEY"] = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  })

  test("domain-separates session, item, and correlation identities", () => {
    expect(agentSessionHash(1, "install", "same")).not.toEqual(agentSourceHash("item", "same"))
    expect(agentSourceHash("item", "same")).not.toEqual(agentSourceHash("correlation", "same"))
    expect(agentSessionHash(1, "install", "same")).toEqual(agentSessionHash(1, "install", "same"))
    expect(agentSourceHash("item", "same")).not.toEqual(agentSourceHash("item", " same"))
  })

  test("round-trips both provider item and Inline correlation refs", () => {
    const encrypted = encryptAgentSourceRefs({
      correlationRef: "inline-message-42",
      itemRef: "provider-item-17",
    })

    expect(decryptAgentSourceRefs(encrypted)).toEqual({
      correlationRef: "inline-message-42",
      itemRef: "provider-item-17",
    })
    expect(encrypted.toString("utf8")).not.toContain("provider-item-17")
  })

  test("rejects empty and oversized references", () => {
    expect(() => encryptAgentSourceRefs({ itemRef: "" })).toThrow()
    expect(() => agentSourceHash("item", "x".repeat(513))).toThrow()
  })
})
