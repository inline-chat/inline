import { and, eq, gt, isNull, lt, or } from "drizzle-orm"
import { db } from "@in/server/db"
import {
  accountIdentities,
  providerAuthAttempts,
  type AccountProvider,
  type DbProviderAuthAttempt,
  type ProviderAuthClient,
  type ProviderAuthPurpose,
  type ProviderAuthStatus,
} from "@in/server/db/schema"

export const ProviderAuthModel = {
  async createAttempt(input: {
    id: string
    provider: AccountProvider
    purpose: ProviderAuthPurpose
    stateHash: string
    nonceHash: string
    nonceEncrypted: Buffer
    pkceVerifierEncrypted?: Buffer
    appCallbackScheme?: string
    appCodeChallenge?: string
    oauthAuthRequestId?: string
    client: ProviderAuthClient
    expiresAt: Date
  }): Promise<DbProviderAuthAttempt> {
    const [attempt] = await db.insert(providerAuthAttempts).values(input).returning()
    if (!attempt) throw new Error("Failed to create provider auth attempt")
    return attempt
  },

  async getActiveByStateHash(stateHash: string): Promise<DbProviderAuthAttempt | undefined> {
    return db.select().from(providerAuthAttempts).where(and(
        eq(providerAuthAttempts.stateHash, stateHash),
        gt(providerAuthAttempts.expiresAt, new Date()),
        isNull(providerAuthAttempts.usedAt),
      )).limit(1).then(([attempt]) => attempt)
  },

  async getActive(id: string): Promise<DbProviderAuthAttempt | undefined> {
    return db.select().from(providerAuthAttempts).where(and(
        eq(providerAuthAttempts.id, id),
        gt(providerAuthAttempts.expiresAt, new Date()),
        isNull(providerAuthAttempts.usedAt),
      )).limit(1).then(([attempt]) => attempt)
  },

  async update(
    id: string,
    values: Partial<typeof providerAuthAttempts.$inferInsert>,
  ): Promise<DbProviderAuthAttempt> {
    const [attempt] = await db
      .update(providerAuthAttempts)
      .set(values)
      .where(and(eq(providerAuthAttempts.id, id), isNull(providerAuthAttempts.usedAt)))
      .returning()
    if (!attempt) throw new Error("Provider auth attempt is unavailable")
    return attempt
  },

  async findIdentity(provider: AccountProvider, subjectHash: string): Promise<number | undefined> {
    const [identity] = await db.select({ userId: accountIdentities.userId }).from(accountIdentities).where(
      and(eq(accountIdentities.provider, provider), eq(accountIdentities.subjectHash, subjectHash)),
    ).limit(1)
    return identity?.userId
  },

  async attachIdentity(input: {
    provider: AccountProvider
    subjectHash: string
    userId: number
  }): Promise<number> {
    await db
      .insert(accountIdentities)
      .values(input)
      .onConflictDoNothing({
        target: [accountIdentities.provider, accountIdentities.subjectHash],
      })

    const owner = await this.findIdentity(input.provider, input.subjectHash)
    if (owner !== input.userId) {
      throw new Error("Provider identity is already attached to another user")
    }
    return owner
  },

  async consumeTicket(
    ticketHash: string,
    appCodeChallenge: string,
  ): Promise<DbProviderAuthAttempt | undefined> {
    return db.transaction(async (tx) => {
      const [attempt] = await tx
        .select()
        .from(providerAuthAttempts)
        .where(and(
          eq(providerAuthAttempts.ticketHash, ticketHash),
          eq(providerAuthAttempts.appCodeChallenge, appCodeChallenge),
          eq(providerAuthAttempts.status, "complete"),
          gt(providerAuthAttempts.expiresAt, new Date()),
          isNull(providerAuthAttempts.usedAt),
        ))
        .for("update")
        .limit(1)
      if (!attempt) return undefined

      const [used] = await tx
        .update(providerAuthAttempts)
        .set({ status: "used", usedAt: new Date() })
        .where(and(eq(providerAuthAttempts.id, attempt.id), isNull(providerAuthAttempts.usedAt)))
        .returning()
      return used
    })
  },

  async cleanupExpired(): Promise<void> {
    await db.delete(providerAuthAttempts).where(or(
      lt(providerAuthAttempts.expiresAt, new Date()),
      and(eq(providerAuthAttempts.status, "used"), lt(providerAuthAttempts.usedAt, new Date(Date.now() - 60_000))),
    ))
  },
}

export type ProviderAttemptUpdate = {
  status?: ProviderAuthStatus
}
