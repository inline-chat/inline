import {
  Context,
  Data,
  Effect,
  ErrorReporter,
} from "effect"
import type {
  AdminActiveUsersQuery,
  AdminCreateEmailCampaignInput,
  AdminEmailCampaignPreviewInput,
  AdminEmailProviderStatusQuery,
  AdminEmailCampaignSendInput,
  AdminEmailCampaignTestInput,
  AdminInviteCountInput,
  AdminInvitesQuery,
  AdminLoginInput,
  AdminSearchQuery,
  AdminSendEmailCodeInput,
  AdminSetPasswordInput,
  AdminStepUpInput,
  AdminTotpCodeInput,
  AdminUpdateUserInput,
  AdminVerifyEmailCodeInput,
} from "./adminSchemas.effect"
import type {
  AdminSessionValue,
} from "./adminSecurity.effect"
import type {
  SessionId,
  UserId,
} from "../core/schema/identifiers"
import type {
  AdminSessionCookieDirective,
} from "./adminCookies.effect"

export interface AdminRequestInfo {
  readonly ip: string | undefined
  readonly origin: string | undefined
  readonly userAgent: string
  readonly publicOrigin: string
  readonly sessionToken: string | undefined
}

export interface AdminJsonResult<A = unknown> {
  readonly kind: "json"
  readonly body: A
  readonly sessionCookie?:
    | AdminSessionCookieDirective
    | undefined
}

export interface AdminRawResult {
  readonly kind: "raw"
  readonly body: BodyInit | null
  readonly headers?: Readonly<
    Record<string, string>
  >
}

export type AdminOperationResult<A = unknown> =
  | AdminJsonResult<A>
  | AdminRawResult

export class AdminRejected extends Data.TaggedError(
  "AdminRejected",
)<{
  readonly status: number
  readonly error: string
  readonly empty?: boolean | undefined
}> {
  override readonly [ErrorReporter.ignore] = true
}

export class AdminOperationFailure extends Data.TaggedError(
  "AdminOperationFailure",
)<{
  readonly operation: string
  readonly cause: unknown
  readonly publicError?: AdminRejected | undefined
}> {}

export type AdminOperationError =
  | AdminRejected
  | AdminOperationFailure

type BodyOf<S extends { readonly Type: unknown }> =
  S["Type"]

type AdminOperation = Effect.Effect<
  AdminOperationResult,
  AdminOperationError
>

export interface AdminOperationsShape {
  readonly devLogin: (
    request: AdminRequestInfo,
  ) => AdminOperation
  readonly sendEmailCode: (
    input: BodyOf<typeof AdminSendEmailCodeInput>,
    request: AdminRequestInfo,
  ) => AdminOperation
  readonly verifyEmailCode: (
    input: BodyOf<typeof AdminVerifyEmailCodeInput>,
    request: AdminRequestInfo,
  ) => AdminOperation
  readonly login: (
    input: BodyOf<typeof AdminLoginInput>,
    request: AdminRequestInfo,
  ) => AdminOperation
  readonly setPassword: (
    input: BodyOf<typeof AdminSetPasswordInput>,
    session: AdminSessionValue,
    request: AdminRequestInfo,
  ) => AdminOperation
  readonly setupTotp: (
    session: AdminSessionValue,
  ) => AdminOperation
  readonly verifyTotp: (
    input: BodyOf<typeof AdminTotpCodeInput>,
    session: AdminSessionValue,
    request: AdminRequestInfo,
  ) => AdminOperation
  readonly stepUp: (
    input: BodyOf<typeof AdminStepUpInput>,
    session: AdminSessionValue,
  ) => AdminOperation
  readonly logout: (
    session: AdminSessionValue,
  ) => AdminOperation
  readonly me: (
    session: AdminSessionValue,
  ) => AdminOperation
  readonly technicalMetrics: (
    session: AdminSessionValue,
  ) => AdminOperation
  readonly appMetrics: (
    session: AdminSessionValue,
  ) => AdminOperation
  readonly overviewMetrics: (
    session: AdminSessionValue,
    request: AdminRequestInfo,
  ) => AdminOperation
  readonly activeUsers: (
    query: BodyOf<typeof AdminActiveUsersQuery>,
    session: AdminSessionValue,
  ) => AdminOperation
  readonly waitlist: (
    query: BodyOf<typeof AdminSearchQuery>,
    session: AdminSessionValue,
  ) => AdminOperation
  readonly emailCampaigns: (
    session: AdminSessionValue,
  ) => AdminOperation
  readonly emailProviderStatus: (
    input: BodyOf<typeof AdminEmailProviderStatusQuery>,
    session: AdminSessionValue,
  ) => AdminOperation
  readonly previewEmailCampaign: (
    input: BodyOf<typeof AdminEmailCampaignPreviewInput>,
    session: AdminSessionValue,
  ) => AdminOperation
  readonly createEmailCampaign: (
    input: BodyOf<typeof AdminCreateEmailCampaignInput>,
    session: AdminSessionValue,
    request: AdminRequestInfo,
  ) => AdminOperation
  readonly testEmailCampaign: (
    campaignId: number,
    input: BodyOf<typeof AdminEmailCampaignTestInput>,
    session: AdminSessionValue,
    request: AdminRequestInfo,
  ) => AdminOperation
  readonly sendEmailCampaign: (
    campaignId: number,
    input: BodyOf<typeof AdminEmailCampaignSendInput>,
    session: AdminSessionValue,
    request: AdminRequestInfo,
  ) => AdminOperation
  readonly pauseEmailCampaign: (
    campaignId: number,
    session: AdminSessionValue,
    request: AdminRequestInfo,
  ) => AdminOperation
  readonly spaces: (
    query: BodyOf<typeof AdminSearchQuery>,
    session: AdminSessionValue,
  ) => AdminOperation
  readonly users: (
    query: BodyOf<typeof AdminSearchQuery>,
    session: AdminSessionValue,
    request: AdminRequestInfo,
  ) => AdminOperation
  readonly avatar: (
    userId: UserId,
    session: AdminSessionValue,
  ) => AdminOperation
  readonly userDetail: (
    userId: UserId,
    session: AdminSessionValue,
    request: AdminRequestInfo,
  ) => AdminOperation
  readonly invites: (
    query: BodyOf<typeof AdminInvitesQuery>,
    session: AdminSessionValue,
  ) => AdminOperation
  readonly generateInvites: (
    input: BodyOf<typeof AdminInviteCountInput>,
    session: AdminSessionValue,
    request: AdminRequestInfo,
  ) => AdminOperation
  readonly grantInvites: (
    userId: UserId,
    input: BodyOf<typeof AdminInviteCountInput>,
    session: AdminSessionValue,
    request: AdminRequestInfo,
  ) => AdminOperation
  readonly revokeSession: (
    userId: UserId,
    sessionId: SessionId,
    session: AdminSessionValue,
    request: AdminRequestInfo,
  ) => AdminOperation
  readonly updateUser: (
    userId: UserId,
    input: BodyOf<typeof AdminUpdateUserInput>,
    session: AdminSessionValue,
    request: AdminRequestInfo,
  ) => AdminOperation
}

export class AdminOperations extends Context.Service<
  AdminOperations,
  AdminOperationsShape
>()("@inline/server/admin/AdminOperations") {}
