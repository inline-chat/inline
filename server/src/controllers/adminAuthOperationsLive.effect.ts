import {
  Effect,
  Random,
} from "effect"
import {
  eq,
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
  isValidEmail,
} from "@in/server/utils/validate"
import {
  normalizeEmail,
} from "@in/server/utils/normalize"
import {
  sendEmail,
} from "@in/server/utils/email"
import {
  encrypt,
} from "@in/server/modules/encryption/encryption"
import {
  buildOtpAuthUrl,
  generateTotpSecret,
  verifyTotpCode,
} from "@in/server/utils/totp"
import {
  issueEmailLoginChallenge,
  verifyEmailLoginChallenge,
} from "@in/server/modules/auth/emailLoginChallenges"
import type {
  AdminOperationsShape,
} from "./adminOperations.effect"
import {
  AdminOperationFailure,
  AdminRejected,
} from "./adminOperations.effect"
import {
  type AdminSessionStoreShape,
} from "./adminSecurity.effect"
import {
  adminSessionCookie,
  clearedAdminSessionCookie,
} from "./adminCookies.effect"
import {
  ADMIN_PASSWORD_MIN_LENGTH,
  ADMIN_TOTP_ISSUER,
  attempt,
  attemptSync,
  createAdminSession,
  getOrCreateAdminUserByEmail,
  getSuperadminByEmail,
  getSuperadminByUserId,
  getTotpSecret,
  jsonResult,
  notifyAdminAction,
  reject,
} from "./adminOperationsSupport.effect"
import {
  type AdminLoginIpRateLimiter,
  makeAdminLoginIpRateLimiter,
} from "./adminLoginRateLimit.effect"
import {
  type AdminEmailChallengeVerifier,
  verifyAdminEmailChallenge,
} from "./adminEmailChallenge.effect"
import {
  DEV_ADMIN_EMAIL,
  isDevAdminLoginAllowed,
} from "./adminDevAuth.effect"

const ADMIN_LOGIN_MAX_ATTEMPTS = 5
const ADMIN_LOGIN_LOCK_MS = 1000 * 60 * 15
const ADMIN_LOGIN_RESET_MS = 1000 * 60 * 60 * 24
const ADMIN_LOGIN_IP_MAX_ATTEMPTS = 30
const ADMIN_LOGIN_IP_WINDOW_MS = 1000 * 60 * 15
const ADMIN_LOGIN_IP_MAX_KEYS = 10_000
const provisionDevAdmin = async () =>
  db.transaction(async (tx) => {
    const user = (await tx
      .insert(users)
      .values({
        email: DEV_ADMIN_EMAIL,
        emailVerified: true,
        firstName: "Local",
        lastName: "Admin",
        pendingSetup: false,
      })
      .onConflictDoUpdate({
        target: users.email,
        set: {
          emailVerified: true,
          firstName: "Local",
          lastName: "Admin",
          pendingSetup: false,
          deleted: false,
        },
      })
      .returning())[0]
    if (!user) throw new Error("Local development admin user was not provisioned")

    await tx
      .insert(superadminUsers)
      .values({ email: DEV_ADMIN_EMAIL, userId: user.id })
      .onConflictDoUpdate({
        target: superadminUsers.email,
        set: { userId: user.id, disabledAt: null },
      })
    return user
  })

type AuthOperationName =
  | "devLogin"
  | "sendEmailCode"
  | "verifyEmailCode"
  | "login"
  | "setPassword"
  | "setupTotp"
  | "verifyTotp"
  | "stepUp"
  | "logout"
  | "me"

export type AdminAuthOperations = Pick<
  AdminOperationsShape,
  AuthOperationName
>

export interface AdminAuthOperationAdapters {
  readonly verifyEmailChallenge?:
    | AdminEmailChallengeVerifier
    | undefined
  readonly loginIpRateLimiter?:
    | AdminLoginIpRateLimiter
    | undefined
}

const publicFailure = (
  operation: string,
  cause: unknown,
  status: number,
  error: string,
) =>
  new AdminOperationFailure({
    operation,
    cause,
    publicError: new AdminRejected({
      status,
      error,
    }),
  })

/**
 * Builds the process-scoped Admin authentication capability.
 *
 * The in-memory IP window intentionally belongs to this Layer-built service,
 * rather than module-global state, so tests and future runtime restarts receive
 * a fresh bounded security window.
 */
export const makeAdminAuthOperations =
  (
    sessionStore: AdminSessionStoreShape,
    adapters: AdminAuthOperationAdapters = {},
  ): AdminAuthOperations => {
    const loginIpRateLimiter =
      adapters.loginIpRateLimiter ??
      makeAdminLoginIpRateLimiter({
        maxAttempts: ADMIN_LOGIN_IP_MAX_ATTEMPTS,
        windowMs: ADMIN_LOGIN_IP_WINDOW_MS,
        maxKeys: ADMIN_LOGIN_IP_MAX_KEYS,
      })
    const emailChallengeVerifier =
      adapters.verifyEmailChallenge ??
      verifyEmailLoginChallenge

    const devLogin: AdminOperationsShape["devLogin"] =
      (request) =>
        Effect.gen(function* () {
          if (!isDevAdminLoginAllowed({
            nodeEnv: process.env.NODE_ENV,
            origin: request.origin,
            ip: request.ip,
          })) {
            return yield* reject(403, "dev_login_unavailable")
          }

          const existing = yield* sessionStore.lookup(
            request.sessionToken,
            request.userAgent,
          ).pipe(
            Effect.mapError((failure) => new AdminOperationFailure({
              operation: "admin.auth.dev-login.session",
              cause: failure.cause,
            })),
          )
          if (existing !== null) return jsonResult({ ok: true as const })

          const user = yield* attempt(
            "admin.auth.dev-login.provision",
            provisionDevAdmin,
          )
          const token = yield* attempt(
            "admin.auth.dev-login.session.create",
            () => createAdminSession({
              userId: user.id,
              ip: request.ip,
              userAgent: request.userAgent,
              stepUpAt: new Date(),
            }),
          )
          return jsonResult(
            { ok: true as const },
            adminSessionCookie(token),
          )
        })

    const sendEmailCode: AdminOperationsShape["sendEmailCode"] =
      (input, request) =>
        Effect.gen(function* () {
          const existing = yield* sessionStore
            .lookup(
              request.sessionToken,
              request.userAgent,
            )
            .pipe(
              Effect.mapError(
                (failure) =>
                  new AdminOperationFailure({
                    operation:
                      "admin.auth.send-email-code.session",
                    cause: failure.cause,
                  }),
              ),
            )
          if (existing !== null) {
            return yield* reject(
              403,
              "already_signed_in",
            )
          }

          if (!isValidEmail(input.email)) {
            return yield* reject(400, "invalid_email")
          }

          const email = normalizeEmail(input.email)
          const adminUser = yield* attempt(
            "admin.auth.send-email-code.lookup",
            () => getSuperadminByEmail(email),
          )
          if (!adminUser?.passwordHash) {
            if (!adminUser) {
              return jsonResult({ ok: true as const })
            }
          } else {
            return jsonResult({ ok: true as const })
          }

          const challenge = yield* attempt(
            "admin.auth.send-email-code.issue",
            async () => {
              const existingUser = (
                await db
                  .select()
                  .from(users)
                  .where(eq(users.email, email))
                  .limit(1)
              )[0]
              const challenge =
                await issueEmailLoginChallenge({ email })
              return {
                ...challenge,
                firstName:
                  existingUser?.firstName ?? undefined,
                isExistingUser:
                  existingUser
                    ? existingUser.pendingSetup !== true
                    : false,
              }
            },
          ).pipe(
            Effect.flatMap(
              ({
                code,
                challengeToken,
                firstName,
                isExistingUser,
              }) =>
              attempt(
                "admin.auth.send-email-code.email",
                () =>
                  sendEmail({
                    to: email,
                    content: {
                      template: "code",
                      variables: {
                        code,
                        firstName,
                        isExistingUser,
                      },
                    },
                  }),
              ).pipe(
                Effect.as(challengeToken),
              ),
            ),
            Effect.mapError((failure) =>
              publicFailure(
                failure.operation,
                failure.cause,
                500,
                "send_failed",
              ),
            ),
          )

          return jsonResult({
            ok: true as const,
            challengeToken: challenge,
          })
        })

    const verifyEmailCode: AdminOperationsShape["verifyEmailCode"] =
      (input, request) =>
        Effect.gen(function* () {
          const existing = yield* sessionStore
            .lookup(
              request.sessionToken,
              request.userAgent,
            )
            .pipe(
              Effect.mapError(
                (failure) =>
                  new AdminOperationFailure({
                    operation:
                      "admin.auth.verify-email-code.session",
                    cause: failure.cause,
                  }),
              ),
            )
          if (existing !== null) {
            return yield* reject(
              403,
              "already_signed_in",
            )
          }

          if (!isValidEmail(input.email)) {
            return yield* reject(400, "invalid_email")
          }
          if (input.code.length < 6) {
            return yield* reject(400, "invalid_code")
          }

          const email = normalizeEmail(input.email)
          const adminUser = yield* attempt(
            "admin.auth.verify-email-code.lookup",
            () => getSuperadminByEmail(email),
          )
          if (!adminUser) {
            return yield* reject(403, "not_allowed")
          }
          if (adminUser.passwordHash) {
            return yield* reject(
              403,
              "password_required",
            )
          }

          const random = yield* Random.Random
          const delay = Math.floor(
            random.nextDoubleUnsafe() * 1000,
          )
          yield* Effect.sleep(`${delay} millis`)

          yield* verifyAdminEmailChallenge(
            {
              email,
              code: input.code,
              challengeToken: input.challengeToken,
            },
            emailChallengeVerifier,
          )

          const user = yield* attempt(
            "admin.auth.verify-email-code.provision-user",
            () => getOrCreateAdminUserByEmail(email),
          )
          if (!user) {
            return yield* Effect.fail(
              publicFailure(
                "admin.auth.verify-email-code.provision-user",
                new Error(
                  "Admin user provisioning returned no user",
                ),
                500,
                "user_missing",
              ),
            )
          }

          if (
            !adminUser.userId ||
            adminUser.userId !== user.id
          ) {
            yield* attempt(
              "admin.auth.verify-email-code.link-user",
              () =>
                db
                  .update(superadminUsers)
                  .set({ userId: user.id })
                  .where(
                    eq(
                      superadminUsers.id,
                      adminUser.id,
                    ),
                  ),
            )
          }

          const token = yield* attempt(
            "admin.auth.verify-email-code.create-session",
            () =>
              createAdminSession({
                userId: user.id,
                ip: request.ip,
                userAgent: request.userAgent,
              }),
          )
          yield* attempt(
            "admin.auth.verify-email-code.notify",
            () =>
              notifyAdminAction({
                actionTaken:
                  "Superadmin login (email code)",
                actorEmail: email,
                request,
              }),
          )

          return jsonResult(
            {
              ok: true as const,
              user: {
                id: user.id,
                email: user.email ?? email,
              },
            },
            adminSessionCookie(token),
          )
        })

    const login: AdminOperationsShape["login"] = (
      input,
      request,
    ) =>
      Effect.gen(function* () {
        if (!isValidEmail(input.email)) {
          return yield* reject(400, "invalid_email")
        }

        const ip = request.ip ?? "unknown"
        const email = normalizeEmail(input.email)
        const adminUser = yield* attempt(
          "admin.auth.login.lookup",
          () => getSuperadminByEmail(email),
        )
        if (!adminUser || adminUser.disabledAt) {
          return yield* reject(403, "not_allowed")
        }

        if (!loginIpRateLimiter.tryRecord(ip)) {
          return yield* reject(429, "login_locked")
        }

        const now = new Date()
        if (
          adminUser.loginLockedUntil &&
          adminUser.loginLockedUntil > now
        ) {
          return yield* reject(429, "login_locked")
        }

        let failedAttempts =
          adminUser.failedLoginAttempts
        if (
          adminUser.lastLoginAttemptAt &&
          now.getTime() -
              adminUser.lastLoginAttemptAt.getTime() >
            ADMIN_LOGIN_RESET_MS &&
          failedAttempts > 0
        ) {
          yield* attempt(
            "admin.auth.login.reset-attempts",
            () =>
              db
                .update(superadminUsers)
                .set({
                  failedLoginAttempts: 0,
                  loginLockedUntil: null,
                  lastLoginAttemptAt: null,
                })
                .where(
                  eq(
                    superadminUsers.id,
                    adminUser.id,
                  ),
                ),
          )
          failedAttempts = 0
        }

        const passwordHash = adminUser.passwordHash
        if (!passwordHash) {
          return yield* reject(
            403,
            "password_not_set",
          )
        }

        const passwordValid = yield* attempt(
          "admin.auth.login.verify-password",
          () =>
            Bun.password.verify(
              input.password,
              passwordHash,
            ),
        )

        const recordFailure = (
          error: "invalid_credentials" | "invalid_totp",
        ) =>
          Effect.gen(function* () {
            // FIXME(effect-cutover): replace this retained read-modify-write
            // counter with one atomic database update under concurrent login failures.
            const nextAttempts = failedAttempts + 1
            const lockedUntil =
              nextAttempts >=
              ADMIN_LOGIN_MAX_ATTEMPTS
                ? new Date(
                    now.getTime() +
                      ADMIN_LOGIN_LOCK_MS,
                  )
                : null
            yield* attempt(
              "admin.auth.login.record-failure",
              () =>
                db
                  .update(superadminUsers)
                  .set({
                    failedLoginAttempts: nextAttempts,
                    lastLoginAttemptAt: now,
                    loginLockedUntil: lockedUntil,
                  })
                  .where(
                    eq(
                      superadminUsers.id,
                      adminUser.id,
                    ),
                  ),
            )
            return yield* reject(
              lockedUntil ? 429 : 401,
              lockedUntil
                ? "login_locked"
                : error,
            )
          })

        if (!passwordValid) {
          return yield* recordFailure(
            "invalid_credentials",
          )
        }

        const totpEnabled = Boolean(
          adminUser.totpEnabledAt,
        )
        if (totpEnabled) {
          const secret = yield* attemptSync(
            "admin.auth.login.decrypt-totp",
            () => getTotpSecret(adminUser),
          )
          if (
            !secret ||
            !verifyTotpCode(
              secret,
              input.totpCode ?? "",
            )
          ) {
            return yield* recordFailure("invalid_totp")
          }
          yield* attempt(
            "admin.auth.login.record-totp-use",
            () =>
              db
                .update(superadminUsers)
                .set({ totpLastUsedAt: new Date() })
                .where(
                  eq(
                    superadminUsers.id,
                    adminUser.id,
                  ),
                ),
          )
        }

        const user = yield* attempt(
          "admin.auth.login.load-user",
          () =>
            adminUser.userId
              ? db
                    .select()
                    .from(users)
                    .where(
                      eq(users.id, adminUser.userId),
                    )
                    .limit(1)
                    .then((rows) => rows[0])
              : getOrCreateAdminUserByEmail(email),
        )
        if (!user) {
          return yield* Effect.fail(
            publicFailure(
              "admin.auth.login.load-user",
              new Error(
                "Admin login resolved no linked user",
              ),
              500,
              "user_missing",
            ),
          )
        }

        if (
          !adminUser.userId ||
          adminUser.userId !== user.id
        ) {
          yield* attempt(
            "admin.auth.login.link-user",
            () =>
              db
                .update(superadminUsers)
                .set({ userId: user.id })
                .where(
                  eq(
                    superadminUsers.id,
                    adminUser.id,
                  ),
                ),
          )
        }

        // TODO(effect-cutover): create the session and reset counters in one
        // transaction so an infrastructure failure cannot leave a hidden live session.
        const token = yield* attempt(
          "admin.auth.login.create-session",
          () =>
            createAdminSession({
              userId: user.id,
              ip: request.ip,
              userAgent: request.userAgent,
              stepUpAt: totpEnabled
                ? new Date()
                : null,
            }),
        )
        yield* attempt(
          "admin.auth.login.reset-success",
          () =>
            db
              .update(superadminUsers)
              .set({
                failedLoginAttempts: 0,
                loginLockedUntil: null,
                lastLoginAttemptAt: now,
              })
              .where(
                eq(
                  superadminUsers.id,
                  adminUser.id,
                ),
              ),
        )
        loginIpRateLimiter.clear(ip)
        yield* attempt(
          "admin.auth.login.notify",
          () =>
            notifyAdminAction({
              actionTaken:
                "Superadmin login (password)",
              actorEmail: email,
              request,
            }),
        )

        return jsonResult(
          { ok: true as const },
          adminSessionCookie(token),
        )
      })

    const setPassword: AdminOperationsShape["setPassword"] =
      (input, session, request) =>
        Effect.gen(function* () {
          const adminUser = yield* attempt(
            "admin.auth.set-password.lookup",
            () =>
              getSuperadminByUserId(session.userId),
          )
          if (!adminUser) {
            return yield* reject(403, "not_allowed")
          }
          if (adminUser.passwordHash) {
            return yield* reject(
              400,
              "password_already_set",
            )
          }
          if (
            input.password.length <
            ADMIN_PASSWORD_MIN_LENGTH
          ) {
            return yield* reject(
              400,
              "password_too_short",
            )
          }

          const passwordHash = yield* attempt(
            "admin.auth.set-password.hash",
            () => Bun.password.hash(input.password),
          )
          yield* attempt(
            "admin.auth.set-password.persist",
            () =>
              db
                .update(superadminUsers)
                .set({
                  passwordHash,
                  passwordSetAt: new Date(),
                })
                .where(
                  eq(
                    superadminUsers.id,
                    adminUser.id,
                  ),
                ),
          )
          yield* attempt(
            "admin.auth.set-password.notify",
            () =>
              notifyAdminAction({
                actionTaken:
                  "Superadmin password set",
                actorEmail: session.email,
                request,
              }),
          )
          return jsonResult({ ok: true as const })
        })

    const setupTotp: AdminOperationsShape["setupTotp"] =
      (session) =>
        Effect.gen(function* () {
          const adminUser = yield* attempt(
            "admin.auth.totp.setup.lookup",
            () =>
              getSuperadminByUserId(session.userId),
          )
          if (!adminUser) {
            return yield* reject(403, "not_allowed")
          }
          if (!adminUser.passwordHash) {
            return yield* reject(
              400,
              "password_required",
            )
          }
          if (adminUser.totpEnabledAt) {
            return yield* reject(
              400,
              "totp_already_enabled",
            )
          }

          const secret = generateTotpSecret()
          const encrypted = yield* attemptSync(
            "admin.auth.totp.setup.encrypt",
            () => encrypt(secret),
          )
          yield* attempt(
            "admin.auth.totp.setup.persist",
            () =>
              db
                .update(superadminUsers)
                .set({
                  totpSecretEncrypted:
                    encrypted.encrypted,
                  totpSecretIv: encrypted.iv,
                  totpSecretTag:
                    encrypted.authTag,
                })
                .where(
                  eq(
                    superadminUsers.id,
                    adminUser.id,
                  ),
                ),
          )

          return jsonResult({
            ok: true as const,
            secret,
            otpauthUrl: buildOtpAuthUrl(
              ADMIN_TOTP_ISSUER,
              session.email,
              secret,
            ),
          })
        })

    const verifyTotp: AdminOperationsShape["verifyTotp"] =
      (input, session, request) =>
        Effect.gen(function* () {
          const adminUser = yield* attempt(
            "admin.auth.totp.verify.lookup",
            () =>
              getSuperadminByUserId(session.userId),
          )
          if (!adminUser) {
            return yield* reject(403, "not_allowed")
          }
          if (adminUser.totpEnabledAt) {
            return yield* reject(
              400,
              "totp_already_enabled",
            )
          }

          const secret = yield* attemptSync(
            "admin.auth.totp.verify.decrypt",
            () => getTotpSecret(adminUser),
          )
          if (
            !secret ||
            !verifyTotpCode(secret, input.code)
          ) {
            return yield* reject(400, "invalid_totp")
          }

          yield* attempt(
            "admin.auth.totp.verify.persist",
            () =>
              db
                .update(superadminUsers)
                .set({
                  totpEnabledAt: new Date(),
                  totpLastUsedAt: new Date(),
                })
                .where(
                  eq(
                    superadminUsers.id,
                    adminUser.id,
                  ),
                ),
          )
          yield* attempt(
            "admin.auth.totp.verify.notify",
            () =>
              notifyAdminAction({
                actionTaken:
                  "Superadmin TOTP enabled",
                actorEmail: session.email,
                request,
              }),
          )
          return jsonResult({ ok: true as const })
        })

    const stepUp: AdminOperationsShape["stepUp"] = (
      input,
      session,
    ) =>
      Effect.gen(function* () {
        const adminUser = yield* attempt(
          "admin.auth.step-up.lookup",
          () => getSuperadminByUserId(session.userId),
        )
        if (!adminUser?.passwordHash) {
          return yield* reject(403, "not_allowed")
        }
        const passwordHash = adminUser.passwordHash
        if (!adminUser.totpEnabledAt) {
          return yield* reject(400, "totp_required")
        }

        const passwordValid = yield* attempt(
          "admin.auth.step-up.verify-password",
          () =>
            Bun.password.verify(
              input.password,
              passwordHash,
            ),
        )
        const secret = yield* attemptSync(
          "admin.auth.step-up.decrypt-totp",
          () => getTotpSecret(adminUser),
        )
        if (
          !passwordValid ||
          !secret ||
          !verifyTotpCode(secret, input.totpCode)
        ) {
          return yield* reject(
            401,
            "invalid_credentials",
          )
        }

        const now = new Date()
        // TODO(effect-cutover): persist both step-up timestamps atomically.
        yield* attempt(
          "admin.auth.step-up.persist",
          async () => {
            await db
              .update(superadminSessions)
              .set({ stepUpAt: now })
              .where(
                eq(
                  superadminSessions.id,
                  session.sessionId,
                ),
              )
            await db
              .update(superadminUsers)
              .set({ totpLastUsedAt: now })
              .where(
                eq(
                  superadminUsers.id,
                  adminUser.id,
                ),
              )
          },
        )
        return jsonResult({
          ok: true as const,
          stepUpAt: now.toISOString(),
        })
      })

    const logout: AdminOperationsShape["logout"] = (
      session,
    ) =>
      attempt("admin.auth.logout.revoke", () =>
        db
          .update(superadminSessions)
          .set({ revokedAt: new Date() })
          .where(
            eq(
              superadminSessions.id,
              session.sessionId,
            ),
          ),
      ).pipe(
        Effect.as(
          jsonResult(
            { ok: true as const },
            clearedAdminSessionCookie(),
          ),
        ),
      )

    const me: AdminOperationsShape["me"] = (session) =>
      Effect.succeed(
        jsonResult({
          ok: true as const,
          user: {
            id: session.userId,
            email: session.email,
            firstName: session.firstName,
            lastName: session.lastName,
          },
          setup: {
            passwordSet: session.passwordSet,
            totpEnabled: session.totpEnabled,
          },
          session: {
            stepUpAt:
              session.stepUpAt?.toISOString() ?? null,
          },
        }),
      )

    return {
      devLogin,
      sendEmailCode,
      verifyEmailCode,
      login,
      setPassword,
      setupTotp,
      verifyTotp,
      stepUp,
      logout,
      me,
    }
  }
