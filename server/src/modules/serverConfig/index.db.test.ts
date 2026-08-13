import { afterEach, describe, expect, it } from "bun:test"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { db } from "@in/server/db"
import { serverConfig } from "@in/server/db/schema"
import { eq, sql } from "drizzle-orm"
import {
  getServerConfig,
  resetServerConfigCacheForTests,
  updateServerConfig,
} from "./index"

describe("server configuration persistence", () => {
  setupTestLifecycle()
  afterEach(resetServerConfigCacheForTests)

  it("uses optimistic versions so stale Admin writes cannot overwrite a newer choice", async () => {
    const admin = await testUtils.createUser("server-config-admin@example.com")
    resetServerConfigCacheForTests()

    const created = await updateServerConfig({
      key: "email.default_provider",
      value: "ses",
      expectedVersion: null,
      updatedByUserId: admin.id,
    })
    expect(created.updated).toBe(true)
    if (!created.updated) throw new Error("Expected initial configuration to be created")
    expect(created.setting.databaseVersion).toBe(1)
    expect(created.setting.databaseValue).toBe("ses")
    expect(created.setting.databaseUpdatedByUserId).toBe(admin.id)

    const staleCreate = await updateServerConfig({
      key: "email.default_provider",
      value: "resend",
      expectedVersion: null,
      updatedByUserId: admin.id,
    })
    expect(staleCreate).toEqual({ updated: false, currentVersion: 1 })

    const updated = await updateServerConfig({
      key: "email.default_provider",
      value: "resend",
      expectedVersion: 1,
      updatedByUserId: admin.id,
    })
    expect(updated.updated).toBe(true)
    if (!updated.updated) throw new Error("Expected matching configuration version to update")
    expect(updated.setting.databaseVersion).toBe(2)
    expect(updated.setting.databaseValue).toBe("resend")

    const staleUpdate = await updateServerConfig({
      key: "email.default_provider",
      value: "ses",
      expectedVersion: 1,
      updatedByUserId: admin.id,
    })
    expect(staleUpdate).toEqual({ updated: false, currentVersion: 2 })

    await db
      .update(serverConfig)
      .set({
        value: "ses",
        version: sql`${serverConfig.version} + 1`,
      })
      .where(eq(serverConfig.key, "email.default_provider"))

    const externallyStaleUpdate = await updateServerConfig({
      key: "email.default_provider",
      value: "resend",
      expectedVersion: 2,
      updatedByUserId: admin.id,
    })
    expect(externallyStaleUpdate).toEqual({ updated: false, currentVersion: 3 })
    expect(await getServerConfig("email.default_provider")).toMatchObject({
      databaseValue: "ses",
      databaseVersion: 3,
    })
  })
})
