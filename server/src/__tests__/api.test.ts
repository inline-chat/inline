import "./setup"

import { describe, expect, it, beforeAll, afterAll } from "bun:test"
import { app } from "../index" // Adjust this import based on your app structure
import { db } from "@in/server/db"
import { loginCodes, users } from "@in/server/db/schema"
import { eq } from "drizzle-orm"
import { migrateDb } from "../../scripts/helpers/migrate-db"
import postgres from "postgres"

beforeAll(async () => {
  // Create the test database
  let parts = process.env.DATABASE_URL.split("/")
  let databaseWithoutDb = parts.slice(0, -1).join("/")
  let newDbUrl = databaseWithoutDb + "/test_db"
  const testDb = postgres(newDbUrl, { max: 1, database: "postgres" })
  await testDb`DROP DATABASE IF EXISTS test_db`
  await testDb`CREATE DATABASE test_db`
  await migrateDb()
})

describe("API Endpoints", () => {
  const testServer = app // Your Elysia app instance

  // Example test
  it(
    "should return 200 for health check",
    async () => {
      const response = await testServer.handle(new Request("http://localhost/"))
      expect(response.status).toBe(200)
      expect(await response.text()).toContain("running")
    },
    { timeout: 10000 },
  )

  it(
    "should create login code and send email",
    async () => {
      let request = new Request("http://localhost/v1/sendEmailCode", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          email: "test@example.com",
        }),
      })

      const response = await testServer.handle(request)
      expect(response.status).toBe(200)
      expect(await response.json()).toMatchObject({
        ok: true,
        result: {
          existingUser: false,
        },
      })
      let loginCodes_ = await db.select().from(loginCodes).where(eq(loginCodes.email, "test@example.com"))
      expect(loginCodes_.length).toBe(1)
      expect(loginCodes_[0]?.code).toBeDefined()
    },
    { timeout: 4000 },
  )

  it(
    "should enter login code and get a token",
    async () => {
      let loginCodes_ = await db.select().from(loginCodes).where(eq(loginCodes.email, "test@example.com"))
      let code = loginCodes_[0]?.code
      let request = new Request("http://localhost/v1/verifyEmailCode", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          email: "test@example.com",
          code: code,
        }),
      })

      const response = await testServer.handle(request)
      expect(response.status).toBe(200)
      let json = await response.json()
      expect(json.ok).toBe(true)
      expect(json.result.token).toBeDefined()

      // Creates a user
      let user = await db.select().from(users).where(eq(users.email, "test@example.com"))
      expect(user.length).toBe(1)
      expect(user[0]?.email).toBe("test@example.com")
    },
    { timeout: 4000 },
  )

  // Add more endpoint tests here
  // Example:
  // it("should create a new user", async () => {
  //   const response = await testServer.handle(
  //     new Request("http://localhost/api/users", {
  //       method: "POST",
  //       headers: {
  //         "Content-Type": "application/json",
  //       },
  //       body: JSON.stringify({
  //         name: "Test User",
  //         email: "test@example.com",
  //       }),
  //     })
  //   );
  //   expect(response.status).toBe(201);
  // });
})
