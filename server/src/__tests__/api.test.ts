import "./setup"

import { describe, expect, it, beforeAll, afterAll } from "bun:test"
import { app } from "../index" // Adjust this import based on your app structure

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
