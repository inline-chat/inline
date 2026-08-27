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
    ENCRYPTION_KEY: "parent-secret",
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
  expect(childEnvironment["NODE_ENV"])
    .toBe("production")
  expect(
    childEnvironment["SKIP_DB_MIGRATIONS"],
  ).toBe("1")

  expect(parentEnvironment).toEqual({
    DATABASE_URL:
      "postgres://localhost:5432/test_db",
    ENCRYPTION_KEY: "parent-secret",
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
