import {
  Effect,
  Schema,
} from "effect"
import {
  and,
  eq,
  isNull,
} from "drizzle-orm"
import {
  db,
} from "@in/server/db"
import {
  superadminSessions,
  superadminUsers,
  users,
} from "@in/server/db/schema"
import {
  generateToken,
  hashToken,
} from "@in/server/utils/auth"
import {
  sendEmail,
} from "@in/server/utils/email"
import {
  Log,
} from "@in/server/utils/log"
import {
  sendInlineOnlyBotEvent,
} from "@in/server/modules/bot-events"
import {
  decrypt,
} from "@in/server/modules/encryption/encryption"
import {
  AdminOperationFailure,
  AdminRejected,
  type AdminJsonResult,
  type AdminOperationResult,
  type AdminRawResult,
  type AdminRequestInfo,
} from "./adminOperations.effect"
import {
  ADMIN_IDLE_MS,
  ADMIN_TTL_MS,
} from "./adminSecurityPolicy.effect"
import {
  AdminSessionPersonalData,
  type AdminSessionPersonalData as AdminSessionPersonalDataValue,
} from "./adminSchemas.effect"

export const ADMIN_PASSWORD_MIN_LENGTH = 12
export const ADMIN_TOTP_ISSUER = "Inline Admin"
export const ADMIN_ACTIVE_USERS_LIMIT = 200

export const jsonResult = <A>(
  body: A,
  sessionCookie?: AdminJsonResult<A>["sessionCookie"],
): AdminJsonResult<A> => ({
  kind: "json",
  body,
  ...(sessionCookie === undefined
    ? {}
    : { sessionCookie }),
})

export const rawResult = (
  body: BodyInit | null,
  headers?: Readonly<Record<string, string>>,
): AdminRawResult => ({
  kind: "raw",
  body,
  ...(headers === undefined ? {} : { headers }),
})

export const reject = (
  status: number,
  error: string,
  options?: {
    readonly empty?: boolean | undefined
  },
): Effect.Effect<never, AdminRejected> =>
  Effect.fail(
    new AdminRejected({
      status,
      error,
      empty: options?.empty,
    }),
  )

export const attempt = <A>(
  operation: string,
  run: () => PromiseLike<A>,
): Effect.Effect<A, AdminOperationFailure> =>
  Effect.tryPromise({
    try: run,
    catch: (cause) =>
      new AdminOperationFailure({
        operation,
        cause,
      }),
  })

export const attemptSync = <A>(
  operation: string,
  run: () => A,
): Effect.Effect<A, AdminOperationFailure> =>
  Effect.try({
    try: run,
    catch: (cause) =>
      new AdminOperationFailure({
        operation,
        cause,
      }),
  })

export const getSuperadminByEmail = async (
  email: string,
) =>
  (
    await db
      .select()
      .from(superadminUsers)
      .where(
        and(
          eq(superadminUsers.email, email),
          isNull(superadminUsers.disabledAt),
        ),
      )
      .limit(1)
  )[0]

export const getSuperadminByUserId = async (
  userId: number,
) =>
  (
    await db
      .select()
      .from(superadminUsers)
      .where(
        and(
          eq(superadminUsers.userId, userId),
          isNull(superadminUsers.disabledAt),
        ),
      )
      .limit(1)
  )[0]

/**
 * Preserves the existing admin provisioning contract behind one reusable
 * capability while keeping database and alert side effects out of handlers.
 */
export const getOrCreateAdminUserByEmail = async (
  email: string,
) => {
  const existing = (
    await db
      .select()
      .from(users)
      .where(eq(users.email, email))
      .limit(1)
  )[0]

  if (!existing) {
    const created = (
      await db
        .insert(users)
        .values({
          email,
          emailVerified: true,
          pendingSetup: false,
        })
        .returning()
    )[0]
    if (created) {
      sendInlineOnlyBotEvent(
        `Superadmin user provisioned: userId=${created.id}`,
      )
    }
    return created
  }

  try {
    await db
      .update(users)
      .set({ pendingSetup: false })
      .where(eq(users.email, email))
  } catch (cause) {
    // TODO(effect-cutover): promote this retained best-effort write to a typed
    // provisioning policy once the legacy admin login path is removed.
    Log.shared.error(
      "Failed to update pending setup to false",
      cause,
    )
  }

  return existing
}

export const getTotpSecret = (
  adminUser: typeof superadminUsers.$inferSelect,
): string | null => {
  if (
    !adminUser.totpSecretEncrypted ||
    !adminUser.totpSecretIv ||
    !adminUser.totpSecretTag
  ) {
    return null
  }

  return decrypt({
    encrypted: adminUser.totpSecretEncrypted,
    iv: adminUser.totpSecretIv,
    authTag: adminUser.totpSecretTag,
  })
}

export const createAdminSession = async (input: {
  readonly userId: number
  readonly ip: string | undefined
  readonly userAgent: string
  readonly stepUpAt?: Date | null | undefined
}) => {
  const now = new Date()
  const expiresAt = new Date(
    now.getTime() + ADMIN_TTL_MS,
  )
  const idleExpiresAt = new Date(
    now.getTime() + ADMIN_IDLE_MS,
  )
  const { token, tokenHash } =
    await generateToken(input.userId)

  await db.insert(superadminSessions).values({
    userId: input.userId,
    tokenHash,
    lastSeenAt: now,
    stepUpAt: input.stepUpAt ?? null,
    expiresAt,
    idleExpiresAt,
    ip: input.ip ?? null,
    userAgentHash: input.userAgent
      ? hashToken(input.userAgent)
      : null,
    date: now,
  })

  return token
}

export const notifyAdminAction = async (
  input: {
    readonly actionTaken: string
    readonly actorEmail: string
    readonly request: AdminRequestInfo
  },
): Promise<void> => {
  try {
    const recipients = await db
      .select({ email: superadminUsers.email })
      .from(superadminUsers)
      .where(isNull(superadminUsers.disabledAt))
    const emails = Array.from(
      new Set(recipients.map((row) => row.email)),
    )
    const timestamp = new Date().toISOString()

    await Promise.all(
      emails.map((email) =>
        sendEmail({
          to: email,
          content: {
            template: "adminAction",
            variables: {
              actionTaken: input.actionTaken,
              actorEmail: input.actorEmail,
              ip: input.request.ip ?? null,
              userAgent:
                input.request.userAgent || null,
              timestamp,
            },
          },
        }),
      ),
    )
  } catch (cause) {
    // TODO(effect-cutover): model audit delivery as an explicit post-commit
    // outcome instead of retaining this best-effort legacy policy.
    Log.shared.error(
      "Failed to send admin action email",
      cause,
    )
  }
}

export const decryptSessionPersonalData = (
  session: {
    readonly personalDataEncrypted: Buffer | null
    readonly personalDataIv: Buffer | null
    readonly personalDataTag: Buffer | null
  },
): AdminSessionPersonalDataValue => {
  try {
    if (
      !session.personalDataEncrypted ||
      !session.personalDataIv ||
      !session.personalDataTag
    ) {
      return {}
    }

    return Schema.decodeUnknownSync(
      AdminSessionPersonalData,
    )(
      JSON.parse(
        decrypt({
          encrypted:
            session.personalDataEncrypted,
          iv: session.personalDataIv,
          authTag: session.personalDataTag,
        }),
      ),
    )
  } catch (cause) {
    Log.shared.error(
      "Failed to decrypt session personal data",
      cause,
    )
    return {}
  }
}

export const getStartOfUtcDay = (
  date: Date,
): Date =>
  new Date(
    Date.UTC(
      date.getUTCFullYear(),
      date.getUTCMonth(),
      date.getUTCDate(),
    ),
  )

export const getStartOfUtcWeek = (
  date: Date,
): Date => {
  const daysSinceMonday =
    (date.getUTCDay() + 6) % 7
  const start = getStartOfUtcDay(date)
  start.setUTCDate(
    start.getUTCDate() - daysSinceMonday,
  )
  return start
}

export const getLast7DaysStart = (): Date =>
  new Date(
    Date.now() - 7 * 24 * 60 * 60 * 1000,
  )

export const parseUserIdSearch = (
  search: string | undefined,
): number | null => {
  const match = search?.match(
    /^(?:(?:user(?:id)?|id)[:#\s-]*)?(\d+)$/i,
  )
  if (!match) {
    return null
  }

  const value = Number(match[1])
  return Number.isSafeInteger(value) && value > 0
    ? value
    : null
}

export type SuccessfulAdminOperation =
  AdminOperationResult<unknown>
