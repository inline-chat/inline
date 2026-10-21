import { describe, expect, it } from "bun:test"
import { isBlockedIp } from "./filters.js"

describe("preview IP filter", () => {
  it("blocks NAT64 addresses that can embed private IPv4", () => {
    expect(isBlockedIp("64:ff9b::a9fe:a9fe")).toBe(true)
    expect(isBlockedIp("64:ff9b::7f00:1")).toBe(true)
    expect(isBlockedIp("64:ff9b:1::a00:1")).toBe(true)
  })

  it("keeps public unicast addresses previewable", () => {
    expect(isBlockedIp("2606:4700:4700::1111")).toBe(false)
    expect(isBlockedIp("93.184.216.34")).toBe(false)
  })
})
