import { describe, expect, it } from "bun:test"
import { validateDevelopmentResetTarget } from "./reset-db"

const developmentEnvironment = {
  nodeEnv: "development",
  ci: undefined,
}

describe("development database reset guard", () => {
  it.each([
    "postgres://localhost:5432/inline_dev",
    "postgres://127.0.0.1:5432/inline_dev",
    "postgres://[::1]:5432/inline_dev",
  ])("allows the exact local development database at %s", (databaseUrl) => {
    expect(
      validateDevelopmentResetTarget(databaseUrl, developmentEnvironment),
    ).toBe(databaseUrl)
  })

  it("rejects a remote database", () => {
    expect(() =>
      validateDevelopmentResetTarget(
        "postgres://db.example.com:5432/inline_dev",
        developmentEnvironment,
      ),
    ).toThrow("Refusing to reset a database on non-local host 'db.example.com'.")
  })

  it("rejects a different local database", () => {
    expect(() =>
      validateDevelopmentResetTarget(
        "postgres://localhost:5432/inline_staging",
        developmentEnvironment,
      ),
    ).toThrow("Refusing to reset database 'inline_staging'; expected 'inline_dev'.")
  })

  it("rejects production and CI", () => {
    expect(() =>
      validateDevelopmentResetTarget("postgres://localhost/inline_dev", {
        nodeEnv: "production",
      }),
    ).toThrow("Refusing to reset a database in production or CI.")

    expect(() =>
      validateDevelopmentResetTarget("postgres://localhost/inline_dev", {
        nodeEnv: "development",
        ci: "true",
      }),
    ).toThrow("Refusing to reset a database in production or CI.")
  })

  it("rejects a missing or malformed URL", () => {
    expect(() =>
      validateDevelopmentResetTarget(undefined, developmentEnvironment),
    ).toThrow("DATABASE_URL is not defined.")
    expect(() =>
      validateDevelopmentResetTarget("not a URL", developmentEnvironment),
    ).toThrow("DATABASE_URL must be a valid URL.")
    expect(() =>
      validateDevelopmentResetTarget(
        "https://localhost/inline_dev",
        developmentEnvironment,
      ),
    ).toThrow("DATABASE_URL must use the postgres or postgresql protocol.")
  })
})
