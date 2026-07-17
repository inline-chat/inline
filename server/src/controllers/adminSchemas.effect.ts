import { Schema } from "effect"
import {
  HttpApiSchema,
} from "effect/unstable/httpapi"
import {
  SessionId,
  UserId,
} from "../core/schema/identifiers"
import {
  InlineId,
  WireNonNegativeInteger,
  WirePositiveInteger,
  WireSafeInteger,
} from "../core/schema/scalars"

const NullableString = Schema.NullOr(Schema.String)
const NullableBoolean = Schema.NullOr(Schema.Boolean)
const NullableInteger = Schema.NullOr(WireSafeInteger)
const NullableInlineId = Schema.NullOr(InlineId)
const NullableUserId = Schema.NullOr(UserId)
const OptionalString = Schema.optionalKey(Schema.String)

export const AdminCookieName = "inline_admin_session" as const

/**
 * Path parameters arrive as strings at the HTTP boundary and are decoded once
 * into the same branded identifiers used by the rest of the server.
 */
export const AdminUserIdParam = Schema.NumberFromString.pipe(
  Schema.decodeTo(UserId),
).annotate({
  identifier: "AdminUserIdParam",
})

export const AdminSessionIdParam = Schema.NumberFromString.pipe(
  Schema.decodeTo(SessionId),
).annotate({
  identifier: "AdminSessionIdParam",
})

const AdminRawUserIdParam = Schema.String.annotate({
  description: "A positive safe-integer user identifier.",
})

const AdminRawSessionIdParam = Schema.String.annotate({
  description: "A positive safe-integer session identifier.",
})

export const AdminSuccess = Schema.Struct({
  ok: Schema.Literal(true),
}).annotate({
  identifier: "AdminSuccess",
})

export const AdminSendEmailCodeInput = Schema.Struct({
  email: Schema.String,
}).annotate({
  identifier: "AdminSendEmailCodeInput",
})

export const AdminSendEmailCodeResult = Schema.Struct({
  ok: Schema.Literal(true),
  challengeToken: OptionalString,
}).annotate({
  identifier: "AdminSendEmailCodeResult",
})

export const AdminVerifyEmailCodeInput = Schema.Struct({
  email: Schema.String,
  code: Schema.String,
  challengeToken: OptionalString,
}).annotate({
  identifier: "AdminVerifyEmailCodeInput",
})

export const AdminVerifyEmailCodeResult = Schema.Struct({
  ok: Schema.Literal(true),
  user: Schema.Struct({
    id: UserId,
    email: Schema.String,
  }),
}).annotate({
  identifier: "AdminVerifyEmailCodeResult",
})

export const AdminLoginInput = Schema.Struct({
  email: Schema.String,
  password: Schema.String,
  totpCode: OptionalString,
}).annotate({
  identifier: "AdminLoginInput",
})

export const AdminSetPasswordInput = Schema.Struct({
  password: Schema.String,
}).annotate({
  identifier: "AdminSetPasswordInput",
})

export const AdminTotpCodeInput = Schema.Struct({
  code: Schema.String,
}).annotate({
  identifier: "AdminTotpCodeInput",
})

export const AdminStepUpInput = Schema.Struct({
  password: Schema.String,
  totpCode: Schema.String,
}).annotate({
  identifier: "AdminStepUpInput",
})

export const AdminTotpSetupResult = Schema.Struct({
  ok: Schema.Literal(true),
  secret: Schema.String,
  otpauthUrl: Schema.String,
}).annotate({
  identifier: "AdminTotpSetupResult",
})

export const AdminStepUpResult = Schema.Struct({
  ok: Schema.Literal(true),
  stepUpAt: Schema.String,
}).annotate({
  identifier: "AdminStepUpResult",
})

export const AdminMeResult = Schema.Struct({
  ok: Schema.Literal(true),
  user: Schema.Struct({
    id: UserId,
    email: Schema.String,
    firstName: NullableString,
    lastName: NullableString,
  }),
  setup: Schema.Struct({
    passwordSet: Schema.Boolean,
    totpEnabled: Schema.Boolean,
  }),
  session: Schema.Struct({
    stepUpAt: NullableString,
  }),
}).annotate({
  identifier: "AdminMeResult",
})

const AdminErrorStats = Schema.Struct({
  last5m: WireNonNegativeInteger,
  last15m: WireNonNegativeInteger,
  total: WireNonNegativeInteger,
})

const DesktopPushSuppressionMetrics = Schema.Struct({
  checksTotal: WireNonNegativeInteger,
  suppressedTotal: WireNonNegativeInteger,
  allowedTotal: WireNonNegativeInteger,
  allowedUrgentNudgeTotal: WireNonNegativeInteger,
  allowedNoRecentDesktopActivityTotal: WireNonNegativeInteger,
  activityRecordedTotal: WireNonNegativeInteger,
  activityIgnoredNonDesktopTotal: WireNonNegativeInteger,
  activityIgnoredUnknownSessionTypeTotal: WireNonNegativeInteger,
  errorsTotal: WireNonNegativeInteger,
  trackedDesktopSessions: WireNonNegativeInteger,
  trackedDesktopChatActivities: WireNonNegativeInteger,
  lastSuppressedAt: NullableInteger,
})

export const AdminTechnicalMetricsResult = Schema.Struct({
  ok: Schema.Literal(true),
  metrics: Schema.Struct({
    server: Schema.Struct({
      version: Schema.String,
      gitCommit: Schema.String,
      startedAt: Schema.String,
      uptimeSeconds: Schema.Number,
      loadAverage: Schema.Array(Schema.Number),
    }),
    memory: Schema.Struct({
      rss: WireNonNegativeInteger,
      heapUsed: WireNonNegativeInteger,
      heapTotal: WireNonNegativeInteger,
    }),
    connections: Schema.Struct({
      total: WireNonNegativeInteger,
      authenticated: WireNonNegativeInteger,
      authenticatedUsers: WireNonNegativeInteger,
      connectedToday: WireNonNegativeInteger,
    }),
    errors: AdminErrorStats,
    notifications: Schema.Struct({
      desktopPushSuppression: DesktopPushSuppressionMetrics,
    }),
  }),
}).annotate({
  identifier: "AdminTechnicalMetricsResult",
})

export const AdminWeeklyActivity = Schema.Struct({
  weekStart: Schema.String,
  weekEnd: Schema.String,
  activeUsers: WireNonNegativeInteger,
  newUsers: WireNonNegativeInteger,
  messages: WireNonNegativeInteger,
  threads: WireNonNegativeInteger,
}).annotate({
  identifier: "AdminWeeklyActivity",
})

export const AdminAppMetrics = Schema.Struct({
  dau: WireNonNegativeInteger,
  wau: WireNonNegativeInteger,
  messagesToday: WireNonNegativeInteger,
  activeUsersToday: WireNonNegativeInteger,
  activeUsersLast7d: WireNonNegativeInteger,
  threadsCreatedToday: WireNonNegativeInteger,
  totals: Schema.Struct({
    totalUsers: WireNonNegativeInteger,
    verifiedUsers: WireNonNegativeInteger,
    onlineUsers: WireNonNegativeInteger,
  }),
  weeklyActivity: Schema.Array(AdminWeeklyActivity),
}).annotate({
  identifier: "AdminAppMetrics",
})

export const AdminAppMetricsResult = Schema.Struct({
  ok: Schema.Literal(true),
  metrics: AdminAppMetrics,
}).annotate({
  identifier: "AdminAppMetricsResult",
})

const AdminRecentUser = Schema.Struct({
  id: UserId,
  email: NullableString,
  firstName: NullableString,
  lastName: NullableString,
  username: NullableString,
  createdAt: NullableString,
  pendingSetup: NullableBoolean,
  avatarUrl: NullableString,
})

const AdminRecentWaitlistEntry = Schema.Struct({
  id: InlineId,
  email: Schema.String,
  name: NullableString,
  verified: Schema.Boolean,
  date: NullableString,
})

const AdminDailyActivity = Schema.Struct({
  date: Schema.String,
  activeUsers: WireNonNegativeInteger,
  newUsers: WireNonNegativeInteger,
})

export const AdminOverviewMetricsResult = Schema.Struct({
  ok: Schema.Literal(true),
  metrics: Schema.Struct({
    dau: WireNonNegativeInteger,
    wau: WireNonNegativeInteger,
    messagesToday: WireNonNegativeInteger,
    mrr: WireNonNegativeInteger,
    connections: Schema.Struct({
      total: WireNonNegativeInteger,
      authenticated: WireNonNegativeInteger,
    }),
    errors: Schema.Struct({
      last5m: WireNonNegativeInteger,
    }),
    waitlistCount: WireNonNegativeInteger,
    newUsersLastDay: WireNonNegativeInteger,
    newWaitlistLastDay: WireNonNegativeInteger,
    recentUsersLastDay: Schema.Array(AdminRecentUser),
    recentWaitlistLastDay: Schema.Array(AdminRecentWaitlistEntry),
    dailyActivity: Schema.Array(AdminDailyActivity),
  }),
}).annotate({
  identifier: "AdminOverviewMetricsResult",
})

export const AdminActiveUsersQuery = Schema.Struct({
  period: Schema.optionalKey(Schema.Literals(["today", "week"])),
}).annotate({
  identifier: "AdminActiveUsersQuery",
})

const AdminActiveUser = Schema.Struct({
  id: UserId,
  email: NullableString,
  firstName: NullableString,
  lastName: NullableString,
  username: NullableString,
  activeDays: WireNonNegativeInteger,
  messageCount: WireNonNegativeInteger,
  lastActive: Schema.String,
})

export const AdminActiveUsersResult = Schema.Struct({
  ok: Schema.Literal(true),
  period: Schema.Literals(["today", "week"]),
  limit: WirePositiveInteger,
  users: Schema.Array(AdminActiveUser),
}).annotate({
  identifier: "AdminActiveUsersResult",
})

export const AdminSearchQuery = Schema.Struct({
  query: OptionalString,
}).annotate({
  identifier: "AdminSearchQuery",
})

export const AdminWaitlistResult = Schema.Struct({
  ok: Schema.Literal(true),
  count: WireNonNegativeInteger,
  entries: Schema.Array(
    Schema.Struct({
      id: InlineId,
      email: Schema.String,
      name: NullableString,
      verified: Schema.Boolean,
      date: NullableString,
    }),
  ),
}).annotate({
  identifier: "AdminWaitlistResult",
})

export const AdminSpacesResult = Schema.Struct({
  ok: Schema.Literal(true),
  spaces: Schema.Array(
    Schema.Struct({
      id: InlineId,
      name: Schema.String,
      handle: NullableString,
      createdAt: NullableString,
      lastUpdateDate: NullableString,
      memberCount: WireNonNegativeInteger,
    }),
  ),
}).annotate({
  identifier: "AdminSpacesResult",
})

const AdminUserSummary = Schema.Struct({
  id: UserId,
  email: NullableString,
  firstName: NullableString,
  lastName: NullableString,
  emailVerified: NullableBoolean,
  username: NullableString,
  phoneNumber: NullableString,
  phoneVerified: NullableBoolean,
  online: NullableBoolean,
  lastOnline: NullableString,
  createdAt: NullableString,
  deleted: NullableBoolean,
  bot: NullableBoolean,
  pendingSetup: NullableBoolean,
  timeZone: NullableString,
  photoFileId: NullableInlineId,
  avatarUrl: NullableString,
})

export const AdminUsersResult = Schema.Struct({
  ok: Schema.Literal(true),
  users: Schema.Array(AdminUserSummary),
}).annotate({
  identifier: "AdminUsersResult",
})

export const AdminUserIdParams = Schema.Struct({
  // Keep route parsing raw so the handler can preserve the legacy error
  // envelope. The Effect replacement intentionally tightens legacy's
  // finite-only detail/update/avatar IDs to positive safe integers.
  id: AdminRawUserIdParam,
}).annotate({
  identifier: "AdminUserIdParams",
})

export const AdminSessionPersonalData = Schema.Struct({
  country: OptionalString,
  region: OptionalString,
  city: OptionalString,
  timezone: OptionalString,
  ip: OptionalString,
  deviceName: OptionalString,
}).annotate({
  identifier: "AdminSessionPersonalData",
})

export type AdminSessionPersonalData =
  typeof AdminSessionPersonalData.Type

export const AdminUserMembership = Schema.Struct({
  id: InlineId,
  role: NullableString,
  canAccessPublicChats: Schema.Boolean,
  invitedBy: NullableUserId,
  joinedAt: NullableString,
  space: Schema.Struct({
    id: InlineId,
    name: Schema.String,
    handle: NullableString,
    isPublic: Schema.Boolean,
    createdAt: NullableString,
    deletedAt: NullableString,
  }),
}).annotate({
  identifier: "AdminUserMembership",
})

export const AdminUserSession = Schema.Struct({
  id: SessionId,
  clientType: NullableString,
  clientVersion: NullableString,
  osVersion: NullableString,
  lastActive: NullableString,
  active: Schema.Boolean,
  deviceId: NullableString,
  date: NullableString,
  revoked: NullableString,
  personalData: AdminSessionPersonalData,
}).annotate({
  identifier: "AdminUserSession",
})

export const AdminUserDetailResult = Schema.Struct({
  ok: Schema.Literal(true),
  user: Schema.Struct({
    id: UserId,
    email: NullableString,
    firstName: NullableString,
    lastName: NullableString,
    emailVerified: NullableBoolean,
    phoneNumber: NullableString,
    phoneVerified: NullableBoolean,
    username: NullableString,
    online: NullableBoolean,
    lastOnline: NullableString,
    createdAt: NullableString,
    deleted: NullableBoolean,
    bot: NullableBoolean,
    botCreatorId: NullableUserId,
    pendingSetup: NullableBoolean,
    timeZone: NullableString,
    lastUpdateDate: NullableString,
    updateSeq: NullableInteger,
    avatarUrl: NullableString,
  }),
  stats: Schema.Struct({
    messages: WireNonNegativeInteger,
    messagesLast7d: WireNonNegativeInteger,
    threadsCreated: WireNonNegativeInteger,
    threadsCreatedLast7d: WireNonNegativeInteger,
    memberships: WireNonNegativeInteger,
    sessions: WireNonNegativeInteger,
    activeSessions: WireNonNegativeInteger,
  }),
  memberships: Schema.Array(AdminUserMembership),
  sessions: Schema.Array(AdminUserSession),
  connections: Schema.Struct({
    totalConnections: WireNonNegativeInteger,
    sessions: Schema.Array(
      Schema.Struct({
        sessionId: SessionId,
        count: WirePositiveInteger,
      }),
    ),
  }),
}).annotate({
  identifier: "AdminUserDetailResult",
})

export const AdminInvitesQuery = Schema.Struct({
  query: OptionalString,
  status: Schema.optionalKey(Schema.Literals(["redeemed", "unredeemed"])),
  ownerUserId: OptionalString,
  redeemedByUserId: OptionalString,
}).annotate({
  identifier: "AdminInvitesQuery",
})

export const AdminInvitesResult = Schema.Struct({
  ok: Schema.Literal(true),
  invites: Schema.Array(
    Schema.Struct({
      id: InlineId,
      code: Schema.String,
      ownerUserId: NullableUserId,
      redeemedByUserId: NullableUserId,
      createdByUserId: NullableUserId,
      note: NullableString,
      createdAt: Schema.String,
      redeemedAt: NullableString,
      redeemed: Schema.Boolean,
    }),
  ),
}).annotate({
  identifier: "AdminInvitesResult",
})

export const AdminInviteCountInput = Schema.Struct({
  count: Schema.Number,
  note: OptionalString,
}).annotate({
  identifier: "AdminInviteCountInput",
})

export const AdminInviteCodesResult = Schema.Struct({
  ok: Schema.Literal(true),
  codes: Schema.Array(Schema.String),
}).annotate({
  identifier: "AdminInviteCodesResult",
})

export const AdminRevokeSessionParams = Schema.Struct({
  id: AdminRawUserIdParam,
  sessionId: AdminRawSessionIdParam,
}).annotate({
  identifier: "AdminRevokeSessionParams",
})

export const AdminRevokeSessionResult = Schema.Struct({
  ok: Schema.Literal(true),
  revoked: Schema.Boolean,
  alreadyRevoked: Schema.Boolean,
}).annotate({
  identifier: "AdminRevokeSessionResult",
})

export const AdminUpdateUserInput = Schema.Struct({
  email: OptionalString,
  firstName: OptionalString,
  lastName: OptionalString,
  emailVerified: Schema.optionalKey(Schema.Boolean),
}).annotate({
  identifier: "AdminUpdateUserInput",
})

export const AdminAvatarBody = Schema.Uint8Array.pipe(
  HttpApiSchema.asUint8Array({
    contentType: "image/*",
  }),
).annotate({
  identifier: "AdminAvatarBody",
  description:
    "Avatar image bytes. The concrete image media type is returned in Content-Type.",
})
