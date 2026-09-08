import { and, eq, inArray, isNull } from "drizzle-orm"
import { db } from "@in/server/db"
import { oauthClients, oauthGrants } from "@in/server/db/schema/oauth"
import { oauthClientKind } from "./clientKind"

/** Active consent grants, not proof of token exchange or a successful MCP call. */
export async function adminOAuthConnections(userIds: number[]) {
  const result = new Map<number, Array<"chatgpt" | "mcp">>()
  if (userIds.length === 0) return result
  const rows = await db.selectDistinct({ userId: oauthGrants.inlineUserId, clientName: oauthClients.clientName })
    .from(oauthGrants)
    .innerJoin(oauthClients, eq(oauthClients.clientId, oauthGrants.clientId))
    .where(and(inArray(oauthGrants.inlineUserId, userIds), isNull(oauthGrants.revokedAt)))
  for (const row of rows) {
    const kinds = result.get(row.userId) ?? []
    const kind = oauthClientKind(row.clientName)
    if (!kinds.includes(kind)) kinds.push(kind)
    result.set(row.userId, kinds.sort())
  }
  return result
}
