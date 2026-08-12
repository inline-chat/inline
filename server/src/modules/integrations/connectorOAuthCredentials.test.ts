import { describe, expect, test } from "bun:test"
import { connectorOAuthCredentials } from "./connectorOAuthCredentials"

describe("connector OAuth credentials", () => {
  test("uses isolated development credentials when configured", () => {
    expect(connectorOAuthCredentials("linear", {
      nodeEnv: "development",
      environment: {
        LINEAR_CLIENT_ID: "production-id",
        LINEAR_CLIENT_SECRET: "production-secret",
        LINEAR_CLIENT_ID_DEV: "development-id",
        LINEAR_CLIENT_SECRET_DEV: "development-secret",
      },
    })).toEqual({
      clientId: "development-id",
      clientSecret: "development-secret",
    })
  })

  test("falls back to production credentials outside production", () => {
    expect(connectorOAuthCredentials("notion", {
      nodeEnv: "test",
      environment: {
        NOTION_CLIENT_ID: "fallback-id",
        NOTION_CLIENT_SECRET: "fallback-secret",
      },
    })).toEqual({ clientId: "fallback-id", clientSecret: "fallback-secret" })
  })

  test("fails closed instead of mixing a partial development pair", () => {
    expect(connectorOAuthCredentials("linear", {
      nodeEnv: "development",
      environment: {
        LINEAR_CLIENT_ID: "production-id",
        LINEAR_CLIENT_SECRET: "production-secret",
        LINEAR_CLIENT_ID_DEV: "development-id",
      },
    })).toBeNull()
  })

  test("never uses development credentials in production", () => {
    expect(connectorOAuthCredentials("linear", {
      nodeEnv: "production",
      environment: {
        LINEAR_CLIENT_ID_DEV: "development-id",
        LINEAR_CLIENT_SECRET_DEV: "development-secret",
      },
    })).toBeNull()
  })
})
