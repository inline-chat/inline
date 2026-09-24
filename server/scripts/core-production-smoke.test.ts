import {
  expect,
  test,
} from "bun:test"
import {
  makeCoreProductionSmokeEnvironment,
} from "./core-production-smoke"
import {
  REQUIRED_PRODUCTION_VARIABLES,
} from "../src/envRequirements"

test("artifact smoke supplies isolated placeholders for production startup", () => {
  const parentEnvironment = {
    DATABASE_URL:
      "postgres://localhost:5432/test_db",
    APPLE_AUTH_PRIVATE_KEY:
      "parent-secret",
    ENCRYPTION_KEY: "parent-secret",
    GOOGLE_AUTH_CLIENT_SECRET:
      "parent-secret",
    RESEND_API_KEY: "parent-secret",
  }

  const childEnvironment =
    makeCoreProductionSmokeEnvironment(
      parentEnvironment,
      true,
    )

  for (
    const variable of
      REQUIRED_PRODUCTION_VARIABLES
  ) {
    expect(childEnvironment[variable]).toBeTruthy()
  }
  expect(
    childEnvironment["DATABASE_URL"],
  ).toBe(parentEnvironment.DATABASE_URL)
  expect(
    childEnvironment["ENCRYPTION_KEY"],
  ).toMatch(/^[0-9a-f]{64}$/)
  expect(
    childEnvironment["ENCRYPTION_KEY"],
  ).not.toBe(parentEnvironment.ENCRYPTION_KEY)
  expect(
    childEnvironment["RESEND_API_KEY"],
  ).not.toBe(parentEnvironment.RESEND_API_KEY)
  expect(
    childEnvironment["GOOGLE_AUTH_CLIENT_ID"],
  ).toBeTruthy()
  expect(
    childEnvironment["GOOGLE_AUTH_CLIENT_SECRET"],
  ).not.toBe(
    parentEnvironment.GOOGLE_AUTH_CLIENT_SECRET,
  )
  expect(
    childEnvironment["APPLE_AUTH_CLIENT_ID"],
  ).toBeTruthy()
  expect(
    childEnvironment["APPLE_AUTH_TEAM_ID"],
  ).toBeTruthy()
  expect(
    childEnvironment["APPLE_AUTH_KEY_ID"],
  ).toBeTruthy()
  expect(
    childEnvironment["APPLE_AUTH_PRIVATE_KEY"],
  ).toContain("BEGIN PRIVATE KEY")
  expect(
    childEnvironment["APPLE_AUTH_PRIVATE_KEY"],
  ).not.toBe(
    parentEnvironment.APPLE_AUTH_PRIVATE_KEY,
  )
  expect(childEnvironment["NODE_ENV"])
    .toBe("production")
  expect(childEnvironment["INLINE_PROCESS_ROLE"])
    .toBe("api")
  expect(childEnvironment["SKIP_DB_MIGRATIONS"]).toBeUndefined()

  expect(parentEnvironment).toEqual({
    DATABASE_URL:
      "postgres://localhost:5432/test_db",
    APPLE_AUTH_PRIVATE_KEY:
      "parent-secret",
    ENCRYPTION_KEY: "parent-secret",
    GOOGLE_AUTH_CLIENT_SECRET:
      "parent-secret",
    RESEND_API_KEY: "parent-secret",
  })
})

test("source smoke remains in test mode without production placeholder overrides", () => {
  const childEnvironment =
    makeCoreProductionSmokeEnvironment(
      {
        DATABASE_URL:
          "postgres://localhost:5432/test_db",
        ENCRYPTION_KEY: "test-key",
      },
      false,
    )

  expect(childEnvironment["NODE_ENV"])
    .toBe("test")
  expect(
    childEnvironment["ENCRYPTION_KEY"],
  ).toBe("test-key")
  expect(childEnvironment["SENTRY_DSN"])
    .toBe("")
})
