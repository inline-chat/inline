import { expect, test } from "bun:test"
import { redactCredentialPath, requiresPrivateResponse } from "./httpPrivacy"
import { setup } from "../setup"
import { botApi } from "../controllers/bot/bot"
import Elysia from "elysia"

test("preserves ordinary diagnostic paths and excludes public Bot documentation from API policy", () => {
  expect(redactCredentialPath("/v1/getMe")).toBe("/v1/getMe")
  expect(redactCredentialPath("/bot/getMe")).toBe("/bot/getMe")
  expect(redactCredentialPath("/bot-api-reference/json")).toBe("/bot-api-reference/json")
  for (const path of ["/bot42%3Asynthetic/getMe", "/botopaque/getMe", "/v1/opaque/logout"]) {
    expect(redactCredentialPath(path)).toContain("<redacted>")
    expect(requiresPrivateResponse(path)).toBeTrue()
  }
  expect(requiresPrivateResponse("/health")).toBeFalse()
  expect(requiresPrivateResponse("/bot-api-reference/json")).toBeFalse()
})

test("legacy HTTP setup adds no-store without changing GET dispatch", async () => {
  const app = new Elysia().use(setup).get("/v1/:token/logout", () => ({ ok: true }))
  const response = await app.handle(new Request("http://localhost/v1/synthetic/logout"))
  expect(response.status).toBe(200)
  expect(response.headers.get("cache-control")).toBe("no-store")
  expect(await response.json()).toEqual({ ok: true })
})

test("legacy Bot API error responses contain the cache and referrer protections", async () => {
  const app = new Elysia().use(botApi)
  const response = await app.handle(new Request("http://localhost/bot/getMe"))
  expect(response.status).toBe(401)
  expect(response.headers.get("cache-control")).toBe("no-store")
  expect(response.headers.get("referrer-policy")).toBe("no-referrer")
})
