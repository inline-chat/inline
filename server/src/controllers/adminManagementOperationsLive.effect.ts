import {
  Effect,
} from "effect"
import {
  and,
  desc,
  eq,
  gte,
  isNull,
  or,
  sql,
} from "drizzle-orm"
import {
  db,
} from "@in/server/db"
import {
  chats,
  inviteCodes,
  members,
  messages,
  sessions,
  spaces,
  superadminUsers,
  users,
  waitlist,
} from "@in/server/db/schema"
import {
  ADMIN_PUBLIC_API_ORIGIN,
} from "@in/server/env"
import {
  FILES_PATH_PREFIX,
} from "@in/server/modules/files/path"
import {
  getR2,
} from "@in/server/libs/r2"
import {
  UsersModel,
} from "@in/server/db/models/users"
import {
  InviteCodesModel,
} from "@in/server/db/models/inviteCodes"
import {
  revokeSession,
} from "@in/server/modules/sessions/revokeSession"
import {
  decrypt,
} from "@in/server/modules/encryption/encryption"
import {
  connectionManager,
} from "@in/server/ws/connections"
import {
  Log,
} from "@in/server/utils/log"
import {
  isValidEmail,
} from "@in/server/utils/validate"
import {
  normalizeEmail,
} from "@in/server/utils/normalize"
import type {
  AdminOperationsShape,
} from "./adminOperations.effect"
import {
  attempt,
  attemptSync,
  decryptSessionPersonalData,
  getLast7DaysStart,
  jsonResult,
  notifyAdminAction,
  parseUserIdSearch,
  rawResult,
  reject,
} from "./adminOperationsSupport.effect"

type ManagementOperationName =
  | "waitlist"
  | "spaces"
  | "users"
  | "avatar"
  | "userDetail"
  | "invites"
  | "generateInvites"
  | "grantInvites"
  | "revokeSession"
  | "updateUser"

export type AdminManagementOperations = Pick<
  AdminOperationsShape,
  ManagementOperationName
>

const userOrigin = (publicOrigin: string): string =>
  ADMIN_PUBLIC_API_ORIGIN ?? publicOrigin

const waitlistOperation: AdminOperationsShape["waitlist"] =
  (query) =>
    attempt("admin.waitlist.list", async () => {
      const search = query.query?.trim()
      const pattern = search ? `%${search}%` : null
      const whereClause = pattern
        ? or(
            sql`${waitlist.email} ILIKE ${pattern}`,
            sql`${waitlist.name} ILIKE ${pattern}`,
          )
        : undefined

      const listQuery = whereClause
        ? db
            .select({
              id: waitlist.id,
              email: waitlist.email,
              name: waitlist.name,
              verified: waitlist.verified,
              date: waitlist.date,
            })
            .from(waitlist)
            .where(whereClause)
        : db
            .select({
              id: waitlist.id,
              email: waitlist.email,
              name: waitlist.name,
              verified: waitlist.verified,
              date: waitlist.date,
            })
            .from(waitlist)

      const countQuery = whereClause
        ? db
            .select({
              count:
                sql<number>`count(*)::int`.as(
                  "count",
                ),
            })
            .from(waitlist)
            .where(whereClause)
        : db
            .select({
              count:
                sql<number>`count(*)::int`.as(
                  "count",
                ),
            })
            .from(waitlist)

      const [rows, countRows] = await Promise.all([
        listQuery
          .orderBy(desc(waitlist.date))
          .limit(200),
        countQuery,
      ])
      return jsonResult({
        ok: true as const,
        count: countRows[0]?.count ?? 0,
        entries: rows.map((row) => ({
          ...row,
          date: row.date?.toISOString() ?? null,
        })),
      })
    })

const spacesOperation: AdminOperationsShape["spaces"] =
  (query) =>
    attempt("admin.spaces.list", async () => {
      const search = query.query?.trim()
      const pattern = search ? `%${search}%` : null
      const searchWhere = pattern
        ? or(
            sql`${spaces.name} ILIKE ${pattern}`,
            sql`${spaces.handle} ILIKE ${pattern}`,
          )
        : undefined
      const whereClause = searchWhere
        ? and(isNull(spaces.deleted), searchWhere)
        : isNull(spaces.deleted)

      const rows = await db
        .select({
          id: spaces.id,
          name: spaces.name,
          handle: spaces.handle,
          createdAt: spaces.date,
          lastUpdateDate: spaces.lastUpdateDate,
          memberCount:
            sql<number>`count(${members.id})::int`,
        })
        .from(spaces)
        .leftJoin(
          members,
          eq(members.spaceId, spaces.id),
        )
        .where(whereClause)
        .groupBy(spaces.id)
        .orderBy(desc(sql`count(${members.id})`))
        .limit(200)

      return jsonResult({
        ok: true as const,
        spaces: rows.map((row) => ({
          ...row,
          createdAt:
            row.createdAt?.toISOString() ?? null,
          lastUpdateDate:
            row.lastUpdateDate?.toISOString() ?? null,
        })),
      })
    })

const usersOperation: AdminOperationsShape["users"] =
  (query, _session, request) =>
    attempt("admin.users.list", async () => {
      const search = query.query?.trim()
      const pattern = search ? `%${search}%` : null
      const userIdSearch = parseUserIdSearch(search)
      const whereClause = search
        ? or(
            ...(userIdSearch
              ? [eq(users.id, userIdSearch)]
              : []),
            sql`${users.email} ILIKE ${pattern}`,
            sql`${users.firstName} ILIKE ${pattern}`,
            sql`${users.lastName} ILIKE ${pattern}`,
            sql`${users.username} ILIKE ${pattern}`,
          )
        : undefined

      const selection = {
        id: users.id,
        email: users.email,
        firstName: users.firstName,
        lastName: users.lastName,
        emailVerified: users.emailVerified,
        username: users.username,
        phoneNumber: users.phoneNumber,
        phoneVerified: users.phoneVerified,
        online: users.online,
        lastOnline: users.lastOnline,
        createdAt: users.date,
        deleted: users.deleted,
        bot: users.bot,
        pendingSetup: users.pendingSetup,
        timeZone: users.timeZone,
        photoFileId: users.photoFileId,
      } as const
      const rows = whereClause
        ? await db
            .select(selection)
            .from(users)
            .where(whereClause)
            .orderBy(desc(users.id))
            .limit(50)
        : await db
            .select(selection)
            .from(users)
            .orderBy(desc(users.id))
            .limit(50)
      const origin = userOrigin(request.publicOrigin)

      return jsonResult({
        ok: true as const,
        users: rows.map((user) => ({
          ...user,
          lastOnline:
            user.lastOnline?.toISOString() ?? null,
          createdAt:
            user.createdAt?.toISOString() ?? null,
          avatarUrl: user.photoFileId
            ? `${origin}/admin/users/${user.id}/avatar`
            : null,
        })),
      })
    })

const avatarOperation: AdminOperationsShape["avatar"] =
  (userId) =>
    Effect.gen(function* () {
      const user = yield* attempt(
        "admin.users.avatar.lookup",
        () => UsersModel.getUserWithProfile(userId),
      )
      const photoFile = user?.photoFile ?? null
      const pathEncrypted =
        photoFile?.pathEncrypted ?? null
      const pathIv = photoFile?.pathIv ?? null
      const pathTag = photoFile?.pathTag ?? null
      const mimeType = photoFile?.mimeType ?? null
      if (
        !pathEncrypted ||
        !pathIv ||
        !pathTag
      ) {
        return yield* reject(404, "not_found", {
          empty: true,
        })
      }

      const path = yield* attemptSync(
        "admin.users.avatar.decrypt",
        () =>
          decrypt({
            encrypted: pathEncrypted,
            iv: pathIv,
            authTag: pathTag,
          }),
      ).pipe(
        Effect.catchTag(
          "AdminOperationFailure",
          (failure) =>
            Effect.sync(() => {
              Log.shared.warn(
                `Failed to decrypt user avatar path for userId=${userId}`,
                failure.cause,
              )
              return null
            }),
        ),
      )
      if (!path) {
        return yield* reject(404, "not_found", {
          empty: true,
        })
      }

      const r2 = yield* attemptSync(
        "admin.users.avatar.storage",
        getR2,
      )
      if (!r2) {
        return yield* reject(
          503,
          "storage_unavailable",
          { empty: true },
        )
      }

      const file = r2.file(
        `${FILES_PATH_PREFIX}/${path}`,
      )
      const exists = yield* attempt(
        "admin.users.avatar.exists",
        () => file.exists(),
      )
      if (!exists) {
        return yield* reject(404, "not_found", {
          empty: true,
        })
      }

      return rawResult(file.stream(), {
        "content-type":
          mimeType ?? "image/jpeg",
        "cache-control": "private, max-age=300",
      })
    })

const userDetailOperation: AdminOperationsShape["userDetail"] =
  (userId, _session, request) =>
    Effect.gen(function* () {
      const user = yield* attempt(
        "admin.users.detail.lookup",
        async () =>
          (
            await db
              .select()
              .from(users)
              .where(eq(users.id, userId))
              .limit(1)
          )[0],
      )
      if (!user) {
        return yield* reject(404, "not_found")
      }

      const detail = yield* attempt(
        "admin.users.detail.related",
        async () => {
          const [
            userSessions,
            userMemberships,
            membershipCountRow,
            messageCountRow,
            recentMessageCountRow,
            threadCountRow,
            recentThreadCountRow,
            sessionCountRow,
            activeSessionCountRow,
          ] = await Promise.all([
            db
              .select({
                id: sessions.id,
                clientType: sessions.clientType,
                clientVersion: sessions.clientVersion,
                osVersion: sessions.osVersion,
                lastActive: sessions.lastActive,
                active: sessions.active,
                deviceId: sessions.deviceId,
                date: sessions.date,
                revoked: sessions.revoked,
                personalDataEncrypted:
                  sessions.personalDataEncrypted,
                personalDataIv:
                  sessions.personalDataIv,
                personalDataTag:
                  sessions.personalDataTag,
              })
              .from(sessions)
              .where(eq(sessions.userId, userId))
              .orderBy(desc(sessions.lastActive))
              .limit(50),
            db
              .select({
                id: members.id,
                role: members.role,
                canAccessPublicChats:
                  members.canAccessPublicChats,
                invitedBy: members.invitedBy,
                joinedAt: members.date,
                spaceId: spaces.id,
                spaceName: spaces.name,
                spaceHandle: spaces.handle,
                spaceIsPublic: spaces.isPublic,
                spaceCreatedAt: spaces.date,
                spaceDeleted: spaces.deleted,
              })
              .from(members)
              .innerJoin(
                spaces,
                eq(members.spaceId, spaces.id),
              )
              .where(eq(members.userId, userId))
              .orderBy(desc(members.date))
              .limit(100),
            db
              .select({
                count: sql<number>`count(*)::int`,
              })
              .from(members)
              .where(eq(members.userId, userId))
              .then((rows) => rows[0]),
            db
              .select({
                count: sql<number>`count(*)::int`,
              })
              .from(messages)
              .where(eq(messages.fromId, userId))
              .then((rows) => rows[0]),
            db
              .select({
                count: sql<number>`count(*)::int`,
              })
              .from(messages)
              .where(
                and(
                  eq(messages.fromId, userId),
                  gte(
                    messages.date,
                    getLast7DaysStart(),
                  ),
                ),
              )
              .then((rows) => rows[0]),
            db
              .select({
                count: sql<number>`count(*)::int`,
              })
              .from(chats)
              .where(
                and(
                  eq(chats.type, "thread"),
                  eq(chats.createdBy, userId),
                ),
              )
              .then((rows) => rows[0]),
            db
              .select({
                count: sql<number>`count(*)::int`,
              })
              .from(chats)
              .where(
                and(
                  eq(chats.type, "thread"),
                  eq(chats.createdBy, userId),
                  gte(
                    chats.date,
                    getLast7DaysStart(),
                  ),
                ),
              )
              .then((rows) => rows[0]),
            db
              .select({
                count: sql<number>`count(*)::int`,
              })
              .from(sessions)
              .where(eq(sessions.userId, userId))
              .then((rows) => rows[0]),
            db
              .select({
                count: sql<number>`count(*)::int`,
              })
              .from(sessions)
              .where(
                and(
                  eq(sessions.userId, userId),
                  eq(sessions.active, true),
                  isNull(sessions.revoked),
                ),
              )
              .then((rows) => rows[0]),
          ])
          return {
            userSessions,
            userMemberships,
            membershipCountRow,
            messageCountRow,
            recentMessageCountRow,
            threadCountRow,
            recentThreadCountRow,
            sessionCountRow,
            activeSessionCountRow,
          }
        },
      )

      const origin = userOrigin(request.publicOrigin)
      return jsonResult({
        ok: true as const,
        user: {
          id: user.id,
          email: user.email,
          firstName: user.firstName,
          lastName: user.lastName,
          emailVerified: user.emailVerified,
          phoneNumber: user.phoneNumber,
          phoneVerified: user.phoneVerified,
          username: user.username,
          online: user.online,
          lastOnline:
            user.lastOnline?.toISOString() ?? null,
          createdAt:
            user.date?.toISOString() ?? null,
          deleted: user.deleted,
          bot: user.bot,
          botCreatorId: user.botCreatorId,
          pendingSetup: user.pendingSetup,
          timeZone: user.timeZone,
          lastUpdateDate:
            user.lastUpdateDate?.toISOString() ?? null,
          updateSeq: user.updateSeq,
          avatarUrl: user.photoFileId
            ? `${origin}/admin/users/${user.id}/avatar`
            : null,
        },
        stats: {
          messages:
            detail.messageCountRow?.count ?? 0,
          messagesLast7d:
            detail.recentMessageCountRow?.count ?? 0,
          threadsCreated:
            detail.threadCountRow?.count ?? 0,
          threadsCreatedLast7d:
            detail.recentThreadCountRow?.count ?? 0,
          memberships:
            detail.membershipCountRow?.count ?? 0,
          sessions:
            detail.sessionCountRow?.count ?? 0,
          activeSessions:
            detail.activeSessionCountRow?.count ?? 0,
        },
        memberships: detail.userMemberships.map(
          (membership) => ({
            id: membership.id,
            role: membership.role,
            canAccessPublicChats: Boolean(
              membership.canAccessPublicChats,
            ),
            invitedBy: membership.invitedBy,
            joinedAt:
              membership.joinedAt?.toISOString() ??
              null,
            space: {
              id: membership.spaceId,
              name: membership.spaceName,
              handle: membership.spaceHandle,
              isPublic: membership.spaceIsPublic,
              createdAt:
                membership.spaceCreatedAt?.toISOString() ??
                null,
              deletedAt:
                membership.spaceDeleted?.toISOString() ??
                null,
            },
          }),
        ),
        sessions: detail.userSessions.map(
          (sessionRow) => ({
            id: sessionRow.id,
            clientType: sessionRow.clientType,
            clientVersion: sessionRow.clientVersion,
            osVersion: sessionRow.osVersion,
            lastActive:
              sessionRow.lastActive?.toISOString() ??
              null,
            active: Boolean(sessionRow.active),
            deviceId: sessionRow.deviceId,
            date:
              sessionRow.date?.toISOString() ?? null,
            revoked:
              sessionRow.revoked?.toISOString() ?? null,
            personalData:
              decryptSessionPersonalData(sessionRow),
          }),
        ),
        connections:
          connectionManager.getUserConnectionSummary(
            userId,
          ),
      })
    })

const invitesOperation: AdminOperationsShape["invites"] =
  (query) =>
    attempt("admin.invites.list", async () => {
      const search = query.query?.trim()
      const filters = []
      if (search) {
        const pattern = `%${search}%`
        filters.push(
          or(
            sql`${inviteCodes.code} ILIKE ${pattern}`,
            sql`${inviteCodes.note} ILIKE ${pattern}`,
          ),
        )
      }
      if (query.status === "redeemed") {
        filters.push(
          sql`${inviteCodes.redeemedAt} IS NOT NULL`,
        )
      } else if (query.status === "unredeemed") {
        filters.push(isNull(inviteCodes.redeemedAt))
      }
      const ownerUserId = query.ownerUserId
        ? Number(query.ownerUserId)
        : null
      if (ownerUserId) {
        filters.push(
          eq(inviteCodes.ownerUserId, ownerUserId),
        )
      }
      const redeemedByUserId =
        query.redeemedByUserId
          ? Number(query.redeemedByUserId)
          : null
      if (redeemedByUserId) {
        filters.push(
          eq(
            inviteCodes.redeemedByUserId,
            redeemedByUserId,
          ),
        )
      }

      const whereClause =
        filters.length > 0 ? and(...filters) : undefined
      const base = db
        .select({
          id: inviteCodes.id,
          code: inviteCodes.code,
          ownerUserId: inviteCodes.ownerUserId,
          redeemedByUserId:
            inviteCodes.redeemedByUserId,
          createdByUserId:
            inviteCodes.createdByUserId,
          note: inviteCodes.note,
          createdAt: inviteCodes.date,
          redeemedAt: inviteCodes.redeemedAt,
        })
        .from(inviteCodes)
      const rows = whereClause
        ? await base
            .where(whereClause)
            .orderBy(desc(inviteCodes.date))
            .limit(200)
        : await base
            .orderBy(desc(inviteCodes.date))
            .limit(200)

      return jsonResult({
        ok: true as const,
        invites: rows.map((row) => ({
          ...row,
          redeemed: row.redeemedAt !== null,
          createdAt: row.createdAt.toISOString(),
          redeemedAt:
            row.redeemedAt?.toISOString() ?? null,
        })),
      })
    })

const validateCount = (
  count: number,
  max: number,
) =>
  Number.isSafeInteger(count) &&
  count >= 1 &&
  count <= max

export const makeAdminManagementOperations =
  (): AdminManagementOperations => ({
    waitlist: waitlistOperation,
    spaces: spacesOperation,
    users: usersOperation,
    avatar: avatarOperation,
    userDetail: userDetailOperation,
    invites: invitesOperation,
    generateInvites: (input, session, request) =>
      Effect.gen(function* () {
        if (!validateCount(input.count, 500)) {
          return yield* reject(400, "invalid_count")
        }
        const rows = yield* attempt(
          "admin.invites.generate",
          () =>
            InviteCodesModel.create({
              count: input.count,
              createdByUserId: session.userId,
              note: input.note,
            }),
        )
        yield* attempt(
          "admin.invites.generate.notify",
          () =>
            notifyAdminAction({
              actionTaken: `Generated ${rows.length} invite codes`,
              actorEmail: session.email,
              request,
            }),
        )
        return jsonResult({
          ok: true as const,
          codes: rows.map((row) => row.code),
        })
      }),
    grantInvites: (
      userId,
      input,
      session,
      request,
    ) =>
      Effect.gen(function* () {
        if (
          !Number.isSafeInteger(userId) ||
          userId <= 0
        ) {
          return yield* reject(400, "invalid_user")
        }
        if (!validateCount(input.count, 100)) {
          return yield* reject(400, "invalid_count")
        }

        const user = yield* attempt(
          "admin.invites.grant.lookup-user",
          async () =>
            (
              await db
                .select({ id: users.id })
                .from(users)
                .where(eq(users.id, userId))
                .limit(1)
            )[0],
        )
        if (!user) {
          return yield* reject(404, "not_found")
        }
        const rows = yield* attempt(
          "admin.invites.grant",
          () =>
            InviteCodesModel.create({
              count: input.count,
              ownerUserId: userId,
              createdByUserId: session.userId,
              note: input.note,
            }),
        )
        yield* attempt(
          "admin.invites.grant.notify",
          () =>
            notifyAdminAction({
              actionTaken: `Granted ${rows.length} invite codes to user ${userId}`,
              actorEmail: session.email,
              request,
            }),
        )
        return jsonResult({
          ok: true as const,
          codes: rows.map((row) => row.code),
        })
      }),
    revokeSession: (
      userId,
      sessionId,
      session,
      request,
    ) =>
      Effect.gen(function* () {
        if (
          !Number.isSafeInteger(userId) ||
          userId <= 0 ||
          !Number.isSafeInteger(sessionId) ||
          sessionId <= 0
        ) {
          return yield* reject(
            400,
            "invalid_session",
          )
        }
        const result = yield* attempt(
          "admin.users.sessions.revoke",
          () =>
            revokeSession({
              actor: "admin",
              actorUserId: session.userId,
              targetUserId: userId,
              sessionId,
            }),
        )
        if (!result.session) {
          return yield* reject(404, "not_found")
        }
        if (result.revoked) {
          yield* attempt(
            "admin.users.sessions.revoke.notify",
            () =>
              notifyAdminAction({
                actionTaken: `Revoked session ${sessionId} for user ${userId}`,
                actorEmail: session.email,
                request,
              }),
          )
        }
        return jsonResult({
          ok: true as const,
          revoked: result.revoked,
          alreadyRevoked: result.alreadyRevoked,
        })
      }),
    updateUser: (
      userId,
      input,
      session,
      request,
    ) =>
      Effect.gen(function* () {
        if (!Number.isFinite(userId)) {
          return yield* reject(400, "invalid_user")
        }

        const updates: Partial<
          typeof users.$inferInsert
        > = {}
        if (
          typeof input.email === "string" &&
          input.email.trim().length > 0
        ) {
          const email = normalizeEmail(input.email)
          if (!isValidEmail(email)) {
            return yield* reject(
              400,
              "invalid_email",
            )
          }
          updates.email = email
        }
        if (typeof input.firstName === "string") {
          updates.firstName = input.firstName
        }
        if (typeof input.lastName === "string") {
          updates.lastName = input.lastName
        }
        if (typeof input.emailVerified === "boolean") {
          updates.emailVerified =
            input.emailVerified
        }
        if (Object.keys(updates).length === 0) {
          return yield* reject(400, "no_updates")
        }

        // TODO(effect-cutover): update the product user and linked superadmin
        // identity in one transaction when the email changes.
        const updated = yield* attempt(
          "admin.users.update",
          async () =>
            (
              await db
                .update(users)
                .set(updates)
                .where(eq(users.id, userId))
                .returning()
            )[0],
        )
        if (!updated) {
          return yield* reject(404, "not_found")
        }
        const updatedEmail = updates.email
        if (typeof updatedEmail === "string") {
          yield* attempt(
            "admin.users.update-admin-email",
            () =>
              db
                .update(superadminUsers)
                .set({ email: updatedEmail })
                .where(
                  eq(
                    superadminUsers.userId,
                    userId,
                  ),
                ),
          )
        }
        yield* attempt(
          "admin.users.update.notify",
          () =>
            notifyAdminAction({
              actionTaken: `Updated user ${userId}`,
              actorEmail: session.email,
              request,
            }),
        )
        return jsonResult({ ok: true as const })
      }),
  })
