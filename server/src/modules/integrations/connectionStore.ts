import { and, desc, eq, isNull } from "drizzle-orm"
import { db } from "@in/server/db"
import { integrations, spaces, users } from "@in/server/db/schema"

export type StoredConnectorProvider = "linear" | "notion"

interface EncryptedConnectorToken {
  encrypted: Buffer
  iv: Buffer
  authTag: Buffer
}

export type ReplacedConnectorToken = EncryptedConnectorToken

/**
 * Reconnects the newest legacy personal row or upserts the unique space row.
 * Locking the owning user serializes personal reconnects without deleting old
 * duplicate rows that may exist from the legacy flow.
 */
export async function storeConnectorToken(input: {
  provider: StoredConnectorProvider
  userId: number
  spaceId: number | null
  token: EncryptedConnectorToken
}): Promise<ReplacedConnectorToken[]> {
  return await db.transaction(async (tx) => {
    if (input.spaceId !== null) {
      const [privateSpace] = await tx
        .select({ id: spaces.id })
        .from(spaces)
        .where(and(
          eq(spaces.id, input.spaceId),
          eq(spaces.isPublic, false),
          isNull(spaces.deleted),
        ))
        .for("update")
        .limit(1)
      if (!privateSpace) {
        throw new Error("Connectors cannot be stored for public or deleted spaces")
      }

      const [existing] = await tx
        .select({
          encrypted: integrations.accessTokenEncrypted,
          iv: integrations.accessTokenIv,
          authTag: integrations.accessTokenTag,
        })
        .from(integrations)
        .where(and(
          eq(integrations.spaceId, input.spaceId),
          eq(integrations.provider, input.provider),
        ))
        .for("update")
        .limit(1)

      await tx
        .insert(integrations)
        .values({
          userId: input.userId,
          spaceId: input.spaceId,
          provider: input.provider,
          accessTokenEncrypted: input.token.encrypted,
          accessTokenIv: input.token.iv,
          accessTokenTag: input.token.authTag,
        })
        .onConflictDoUpdate({
          target: [integrations.spaceId, integrations.provider],
          set: {
            userId: input.userId,
            accessTokenEncrypted: input.token.encrypted,
            accessTokenIv: input.token.iv,
            accessTokenTag: input.token.authTag,
            notionDatabaseId: input.provider === "notion" ? null : undefined,
            linearTeamId: input.provider === "linear" ? null : undefined,
            date: new Date(),
          },
        })
      return existing?.encrypted && existing.iv && existing.authTag
        ? [{ encrypted: existing.encrypted, iv: existing.iv, authTag: existing.authTag }]
        : []
    }

    await tx
      .select({ id: users.id })
      .from(users)
      .where(eq(users.id, input.userId))
      .for("update")
      .limit(1)

    const existingRows = await tx
      .select({
        id: integrations.id,
        encrypted: integrations.accessTokenEncrypted,
        iv: integrations.accessTokenIv,
        authTag: integrations.accessTokenTag,
      })
      .from(integrations)
      .where(and(
        eq(integrations.userId, input.userId),
        isNull(integrations.spaceId),
        eq(integrations.provider, input.provider),
      ))
      .orderBy(desc(integrations.date), desc(integrations.id))
    const [existing] = existingRows

    if (existing) {
      await tx
        .update(integrations)
        .set({
          accessTokenEncrypted: input.token.encrypted,
          accessTokenIv: input.token.iv,
          accessTokenTag: input.token.authTag,
          date: new Date(),
        })
        .where(eq(integrations.id, existing.id))
      return existingRows.flatMap((row) =>
        row.encrypted && row.iv && row.authTag
          ? [{ encrypted: row.encrypted, iv: row.iv, authTag: row.authTag }]
          : [],
      )
    }

    await tx.insert(integrations).values({
      userId: input.userId,
      spaceId: null,
      provider: input.provider,
      accessTokenEncrypted: input.token.encrypted,
      accessTokenIv: input.token.iv,
      accessTokenTag: input.token.authTag,
    })
    return []
  })
}
