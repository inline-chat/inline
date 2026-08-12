import { describe, expect, test } from "bun:test"
import { eq } from "drizzle-orm"
import { db } from "@in/server/db"
import { integrations, spaces } from "@in/server/db/schema"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { storeConnectorToken } from "./connectionStore"

describe("connector connection store", () => {
  setupTestLifecycle()

  test("rejects credentials for public spaces", async () => {
    const user = await testUtils.createUser("public-connector-owner@example.com")
    const [space] = await db.insert(spaces).values({
      name: "Public Community",
      isPublic: true,
    }).returning()
    if (!space) throw new Error("space not created")

    await expect(storeConnectorToken({
      provider: "notion",
      userId: user.id,
      spaceId: space.id,
      token: {
        encrypted: Buffer.from("encrypted"),
        iv: Buffer.from("iv"),
        authTag: Buffer.from("tag"),
      },
    })).rejects.toThrow("Connectors cannot be stored for public or deleted spaces")

    const rows = await db
      .select({ id: integrations.id })
      .from(integrations)
      .where(eq(integrations.spaceId, space.id))
    expect(rows).toHaveLength(0)
  })

  test("clears a provider target when reconnecting a space", async () => {
    const user = await testUtils.createUser("reconnect-owner@example.com")
    const [space] = await db.insert(spaces).values({ name: "Reconnect Space" }).returning()
    if (!space) throw new Error("space not created")
    await db.insert(integrations).values({
      userId: user.id,
      spaceId: space.id,
      provider: "linear",
      linearTeamId: "old-team",
      accessTokenEncrypted: Buffer.from("old-encrypted"),
      accessTokenIv: Buffer.from("old-iv"),
      accessTokenTag: Buffer.from("old-tag"),
    })

    const replaced = await storeConnectorToken({
      provider: "linear",
      userId: user.id,
      spaceId: space.id,
      token: {
        encrypted: Buffer.from("new-encrypted"),
        iv: Buffer.from("new-iv"),
        authTag: Buffer.from("new-tag"),
      },
    })

    const [stored] = await db
      .select()
      .from(integrations)
      .where(eq(integrations.spaceId, space.id))
    expect(stored?.linearTeamId).toBeNull()
    expect(stored?.accessTokenEncrypted).toEqual(Buffer.from("new-encrypted"))
    expect(replaced).toEqual([{
      encrypted: Buffer.from("old-encrypted"),
      iv: Buffer.from("old-iv"),
      authTag: Buffer.from("old-tag"),
    }])
  })
})
