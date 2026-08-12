import { createHash } from "node:crypto"
import { and, eq, gt, lt } from "drizzle-orm"
import { db } from "@in/server/db"
import { integrationOAuthStates } from "@in/server/db/schema"

export type ConnectorOAuthProvider = "linear" | "notion"

export interface ConnectorOAuthIdentity {
  userId: number
  spaceId: number | null
  callbackScheme: string
}

const STATE_TTL_MS = 10 * 60 * 1_000

const hashState = (state: string): string =>
  createHash("sha256").update(state).digest("hex")

export async function storeConnectorOAuthState(input: {
  state: string
  provider: ConnectorOAuthProvider
  callbackScheme: string
  userId: number
  spaceId: number | null
  now?: Date
}): Promise<void> {
  const now = input.now ?? new Date()

  await db.transaction(async (tx) => {
    await tx
      .delete(integrationOAuthStates)
      .where(lt(integrationOAuthStates.expiresAt, now))

    await tx.insert(integrationOAuthStates).values({
      stateHash: hashState(input.state),
      provider: input.provider,
      callbackScheme: input.callbackScheme,
      userId: input.userId,
      spaceId: input.spaceId,
      expiresAt: new Date(now.getTime() + STATE_TTL_MS),
    })
  })
}

/** Claims and deletes a valid state in one statement, making callbacks replay-safe. */
export async function claimConnectorOAuthState(
  state: string,
  provider: ConnectorOAuthProvider,
  now = new Date(),
): Promise<ConnectorOAuthIdentity | null> {
  const [claimed] = await db
    .delete(integrationOAuthStates)
    .where(and(
      eq(integrationOAuthStates.stateHash, hashState(state)),
      eq(integrationOAuthStates.provider, provider),
      gt(integrationOAuthStates.expiresAt, now),
    ))
    .returning({
      userId: integrationOAuthStates.userId,
      spaceId: integrationOAuthStates.spaceId,
      callbackScheme: integrationOAuthStates.callbackScheme,
    })

  return claimed ?? null
}
