import { describe, expect, it } from "vitest"
import { isDevAdminLoginAllowed } from "./adminDevAuth.effect"

describe("admin development login policy", () => {
  it("allows only the local Vite origin from a loopback client in development", () => {
    expect(isDevAdminLoginAllowed({
      nodeEnv: "development",
      origin: "http://127.0.0.1:5174",
      ip: "127.0.0.1",
    })).toBe(true)
    expect(isDevAdminLoginAllowed({
      nodeEnv: "development",
      origin: "http://localhost:5174",
      ip: "::1",
    })).toBe(true)
  })

  it("fails closed in production and for non-local callers", () => {
    expect(isDevAdminLoginAllowed({
      nodeEnv: "production",
      origin: "http://localhost:5174",
      ip: "127.0.0.1",
    })).toBe(false)
    expect(isDevAdminLoginAllowed({
      nodeEnv: "development",
      origin: "https://admin.inline.chat",
      ip: "127.0.0.1",
    })).toBe(false)
    expect(isDevAdminLoginAllowed({
      nodeEnv: "development",
      origin: "http://localhost:5174",
      ip: "192.168.1.20",
    })).toBe(false)
    expect(isDevAdminLoginAllowed({
      nodeEnv: "development",
      origin: undefined,
      ip: "127.0.0.1",
    })).toBe(false)
  })
})
