import {
  Effect,
} from "effect"
import {
  and,
  desc,
  eq,
  gte,
  inArray,
  isNull,
  or,
  sql,
} from "drizzle-orm"
import {
  db,
} from "@in/server/db"
import {
  chats,
  emailCampaignRecipients,
  emailCampaigns,
  emailSuppressions,
  inviteCodes,
  members,
  messages,
  sessions,
  spaces,
  superadminUsers,
  users,
  waitlist,
} from "@in/server/db/schema"
import { isValidEmail } from "@in/server/utils/validate"
import {
  createUnsubscribeToken,
  decryptCampaignString,
  encryptCampaignString,
  hashUnsubscribeToken,
  normalizedCampaignEmail,
} from "@in/server/modules/emailCampaigns/contactCrypto"
import { resolveCampaignAudience } from "@in/server/modules/emailCampaigns/audience"
import {
  type CampaignFromAddress,
  createResendBroadcast,
  createResendCampaignSegment,
  deliverCampaignTestEmail,
  deliverSesCampaignBatch,
  removeResendCampaignRecipients,
  sendResendBroadcast,
  syncResendCampaignRecipients,
} from "@in/server/modules/emailCampaigns/delivery"
import { renderCampaign } from "@in/server/modules/emailCampaigns/render"
import { getEmailProviderStatus } from "@in/server/modules/emailCampaigns/providerStatus"
import { syncProviderSuppressions } from "@in/server/modules/emailCampaigns/providerSuppressions"
import type { EmailCampaignAudience } from "@in/server/modules/emailCampaigns/types"
import {
  ADMIN_PUBLIC_API_ORIGIN,
  EMAIL_PROVIDER,
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
  | "emailCampaigns"
  | "emailProviderStatus"
  | "previewEmailCampaign"
  | "createEmailCampaign"
  | "testEmailCampaign"
  | "sendEmailCampaign"
  | "pauseEmailCampaign"
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

const campaignSummary = async (campaignId?: number) => {
  const whereClause = campaignId === undefined
    ? undefined
    : eq(emailCampaigns.id, campaignId)
  const query = db
    .select({
      id: emailCampaigns.id,
      name: emailCampaigns.name,
      seriesKey: emailCampaigns.seriesKey,
      subject: emailCampaigns.subject,
      provider: emailCampaigns.provider,
      fromAddress: emailCampaigns.fromAddress,
      status: emailCampaigns.status,
      recipientCount: emailCampaigns.recipientCount,
      pendingCount: sql<number>`count(*) filter (where ${emailCampaignRecipients.status} = 'pending')::int`,
      preparedCount: sql<number>`count(*) filter (where ${emailCampaignRecipients.status} = 'provider_synced')::int`,
      contactedCount: sql<number>`count(*) filter (where ${emailCampaignRecipients.status} in ('sending', 'provider_accepted', 'unknown'))::int`,
      suppressedCount: sql<number>`count(*) filter (where ${emailCampaignRecipients.status} = 'suppressed')::int`,
      testSentAt: emailCampaigns.testSentAt,
      createdAt: emailCampaigns.createdAt,
      completedAt: emailCampaigns.completedAt,
    })
    .from(emailCampaigns)
    .leftJoin(
      emailCampaignRecipients,
      eq(emailCampaignRecipients.campaignId, emailCampaigns.id),
    )
    .groupBy(emailCampaigns.id)

  const rows = whereClause
    ? await query.where(whereClause).limit(1)
    : await query.orderBy(desc(emailCampaigns.createdAt)).limit(100)
  return rows.map((row) => ({
    ...row,
    provider: selectedCampaignProvider(row.provider),
    fromAddress: selectedCampaignFromAddress(row.fromAddress),
    testSentAt: row.testSentAt?.toISOString() ?? null,
    createdAt: row.createdAt.toISOString(),
    completedAt: row.completedAt?.toISOString() ?? null,
  }))
}

const selectedCampaignProvider = (provider: string | null): "resend" | "ses" => {
  if (provider === "resend" || provider === "ses") return provider
  return EMAIL_PROVIDER === "SES" ? "ses" : "resend"
}

const selectedCampaignFromAddress = (fromAddress: string): CampaignFromAddress => {
  if (
    fromAddress === "team@inline.chat" ||
    fromAddress === "founders@inline.chat" ||
    fromAddress === "mo@inline.chat"
  ) return fromAddress
  return "team@inline.chat"
}

const validateAudience = (audience: EmailCampaignAudience): string | null => {
  if (audience.sources.length === 0 && audience.manualEmails.length === 0) return "empty_audience"
  if (audience.manualEmails.length > 500) return "too_many_manual_emails"
  if (audience.limit !== undefined && (!Number.isInteger(audience.limit) || audience.limit < 1 || audience.limit > 10_000)) {
    return "invalid_limit"
  }
  if (
    audience.activeWithinDays !== undefined &&
    (!Number.isInteger(audience.activeWithinDays) || audience.activeWithinDays < 1 || audience.activeWithinDays > 3_650)
  ) {
    return "invalid_activity_window"
  }
  if (audience.sampleSeed.trim().length === 0 || audience.sampleSeed.length > 160) return "invalid_sample_seed"
  if (audience.excludeCampaignIds.some((id) => !Number.isSafeInteger(id) || id <= 0)) return "invalid_campaign_exclusion"
  return null
}

const emailCampaignsOperation: AdminOperationsShape["emailCampaigns"] =
  () =>
    attempt("admin.email-campaigns.list", async () =>
      jsonResult({ ok: true as const, campaigns: await campaignSummary() }),
    )

const emailProviderStatusOperation: AdminOperationsShape["emailProviderStatus"] =
  (input) =>
    attempt("admin.email-provider-status", async () =>
      jsonResult({ ok: true as const, providerStatus: await getEmailProviderStatus(input.provider) }),
    )

const previewEmailCampaignOperation: AdminOperationsShape["previewEmailCampaign"] =
  (input) =>
    Effect.gen(function* () {
      const validationError = validateAudience(input.audience as EmailCampaignAudience)
      if (validationError) return yield* reject(400, validationError)
      yield* attempt("admin.email-campaigns.preview.suppressions", () =>
        syncProviderSuppressions(input.provider),
      )
      const preview = yield* attempt("admin.email-campaigns.preview", () =>
        resolveCampaignAudience(input.audience as EmailCampaignAudience),
      )
      const sampleRecipient = preview.recipients[0]
      const variables = {
        name: input.previewName?.trim() || sampleRecipient?.name || "there",
        email: sampleRecipient?.email || "preview@inline.chat",
      }
      const rendered = yield* attempt("admin.email-campaigns.preview.render", () =>
        renderCampaign({
          subject: input.subject || "Your campaign subject",
          previewText: input.previewText,
          bodyText: input.bodyText || "Your **Markdown** campaign will appear here.",
          variables,
          unsubscribeUrl: "https://api.inline.chat/email/unsubscribe/preview",
          visibleUnsubscribe: input.visibleUnsubscribe,
        }),
      )
      return jsonResult({
        ok: true as const,
        count: preview.recipients.length,
        sample: preview.recipients.slice(0, 20).map(({ email, name, sources }) => ({ email, name, sources })),
        excluded: preview.excluded,
        rendered: {
          subject: rendered.subject,
          html: rendered.html,
          text: rendered.text,
          variables,
        },
      })
    })

const createEmailCampaignOperation: AdminOperationsShape["createEmailCampaign"] =
  (input, session, request) =>
    Effect.gen(function* () {
      const name = input.name.trim()
      const subject = input.subject.trim()
      const previewText = input.previewText?.trim() || null
      const bodyText = input.bodyText.trim()
      const validationError = validateAudience(input.audience as EmailCampaignAudience)
      if (!name || name.length > 160) return yield* reject(400, "invalid_name")
      if (!subject || subject.length > 240) return yield* reject(400, "invalid_subject")
      if (previewText && previewText.length > 240) return yield* reject(400, "invalid_preview_text")
      if (!bodyText || bodyText.length > 20_000) return yield* reject(400, "invalid_body")
      const unsubscribeOverrideReason = input.unsubscribeOverrideReason?.trim() || null
      if (!input.visibleUnsubscribe && (!unsubscribeOverrideReason || unsubscribeOverrideReason.length < 20)) {
        return yield* reject(400, "unsubscribe_override_reason_required")
      }
      if (input.confirmation !== `FREEZE ${name}`) return yield* reject(400, "confirmation_mismatch")
      if (validationError) return yield* reject(400, validationError)

      yield* attempt("admin.email-campaigns.create.suppressions", () =>
        syncProviderSuppressions(input.provider, { force: true }),
      )
      const preview = yield* attempt("admin.email-campaigns.resolve", () =>
        resolveCampaignAudience(input.audience as EmailCampaignAudience),
      )
      if (preview.recipients.length === 0) return yield* reject(400, "empty_audience")

      const created = yield* attempt("admin.email-campaigns.create", () =>
        db.transaction(async (tx) => {
          const campaign = (await tx
            .insert(emailCampaigns)
            .values({
              name,
              provider: input.provider,
              fromAddress: input.fromAddress,
              seriesKey: input.seriesKey?.trim() || null,
              subject,
              previewText,
              bodyText,
              audience: input.audience,
              recipientCount: preview.recipients.length,
              createdByUserId: session.userId,
              visibleUnsubscribe: input.visibleUnsubscribe,
              unsubscribeOverrideReason: input.visibleUnsubscribe ? null : unsubscribeOverrideReason,
            })
            .returning())[0]
          if (!campaign) throw new Error("Campaign insert returned no row")

          const recipientValues = preview.recipients.map((recipient) => {
              const token = createUnsubscribeToken()
              return {
                campaignId: campaign.id,
                emailKey: recipient.emailKey,
                emailEncrypted: encryptCampaignString(recipient.email),
                nameEncrypted: recipient.name ? encryptCampaignString(recipient.name) : null,
                unsubscribeTokenHash: hashUnsubscribeToken(token),
                unsubscribeTokenEncrypted: encryptCampaignString(token),
                sources: recipient.sources,
              }
            })
          for (let index = 0; index < recipientValues.length; index += 500) {
            await tx.insert(emailCampaignRecipients).values(
              recipientValues.slice(index, index + 500),
            )
          }
          return campaign.id
        }),
      )
      yield* attempt("admin.email-campaigns.create.notify", () =>
        notifyAdminAction({
          actionTaken: `Froze email campaign ${created} (${preview.recipients.length} recipients)`,
          actorEmail: session.email,
          request,
        }),
      )
      const campaign = (yield* attempt("admin.email-campaigns.created", () => campaignSummary(created)))[0]
      if (!campaign) return yield* reject(500, "server_error")
      return jsonResult({ ok: true as const, campaign })
    })

const testEmailCampaignOperation: AdminOperationsShape["testEmailCampaign"] =
  (campaignId, input, session, request) =>
    Effect.gen(function* () {
      const email = normalizedCampaignEmail(input.email)
      if (!Number.isSafeInteger(campaignId) || campaignId <= 0) return yield* reject(400, "invalid_campaign")
      if (!isValidEmail(email)) return yield* reject(400, "invalid_email")
      const campaign = yield* attempt("admin.email-campaigns.test.lookup", async () =>
        (await db.select().from(emailCampaigns).where(eq(emailCampaigns.id, campaignId)).limit(1))[0],
      )
      if (!campaign) return yield* reject(404, "not_found")
      const token = createUnsubscribeToken()
      yield* attempt("admin.email-campaigns.test.deliver", () =>
        deliverCampaignTestEmail({
          provider: selectedCampaignProvider(campaign.provider),
          fromAddress: selectedCampaignFromAddress(campaign.fromAddress),
          to: email,
          name: input.name?.trim() || undefined,
          subject: `[TEST] ${campaign.subject}`,
          previewText: campaign.previewText ?? undefined,
          bodyText: campaign.bodyText,
          unsubscribeToken: token,
          visibleUnsubscribe: campaign.visibleUnsubscribe,
        }),
      )
      yield* attempt("admin.email-campaigns.test.mark", () =>
        db.update(emailCampaigns).set({ testSentAt: new Date() }).where(eq(emailCampaigns.id, campaignId)),
      )
      yield* attempt("admin.email-campaigns.test.notify", () =>
        notifyAdminAction({
          actionTaken: `Tested email campaign ${campaignId}`,
          actorEmail: session.email,
          request,
        }),
      )
      return jsonResult({ ok: true as const })
    })

const sendEmailCampaignOperation: AdminOperationsShape["sendEmailCampaign"] =
  (campaignId, input, session, request) =>
    Effect.gen(function* () {
      if (!Number.isSafeInteger(campaignId) || campaignId <= 0) return yield* reject(400, "invalid_campaign")
      if (!Number.isInteger(input.batchSize) || input.batchSize < 1 || input.batchSize > 50) {
        return yield* reject(400, "invalid_batch_size")
      }
      const campaign = yield* attempt("admin.email-campaigns.send.lookup", async () =>
        (await db.select().from(emailCampaigns).where(eq(emailCampaigns.id, campaignId)).limit(1))[0],
      )
      if (!campaign) return yield* reject(404, "not_found")
      if (!campaign.testSentAt) return yield* reject(400, "test_send_required")
      if (!["frozen", "sending", "paused"].includes(campaign.status)) return yield* reject(400, "campaign_not_sendable")
      if (input.confirmation !== `SEND ${campaign.name}`) return yield* reject(400, "confirmation_mismatch")
      yield* attempt("admin.email-campaigns.send.suppressions", () =>
        syncProviderSuppressions(selectedCampaignProvider(campaign.provider), { force: true }),
      )

      const claimed = yield* attempt("admin.email-campaigns.send.claim", () =>
        db.transaction(async (tx) => {
          await tx
            .update(emailCampaignRecipients)
            .set({ status: "suppressed" })
            .where(and(
              eq(emailCampaignRecipients.campaignId, campaignId),
              eq(emailCampaignRecipients.status, "pending"),
              inArray(
                emailCampaignRecipients.emailKey,
                tx.select({ emailKey: emailSuppressions.emailKey }).from(emailSuppressions),
              ),
            ))
          const rows = await tx
            .select()
            .from(emailCampaignRecipients)
            .where(and(
              eq(emailCampaignRecipients.campaignId, campaignId),
              eq(emailCampaignRecipients.status, "pending"),
            ))
            .orderBy(emailCampaignRecipients.id)
            .limit(input.batchSize)
            .for("update", { skipLocked: true })
          if (rows.length > 0) {
            await tx
              .update(emailCampaignRecipients)
              .set({
                status: "sending",
                attemptCount: sql`${emailCampaignRecipients.attemptCount} + 1`,
                lastAttemptAt: new Date(),
              })
              .where(inArray(emailCampaignRecipients.id, rows.map((row) => row.id)))
            await tx.update(emailCampaigns).set({ status: "sending" }).where(eq(emailCampaigns.id, campaignId))
          }
          return rows
        }),
      )

      const bulkRecipients = claimed.map((recipient) => ({
        id: recipient.id,
        email: decryptCampaignString(recipient.emailEncrypted),
        name: recipient.nameEncrypted ? decryptCampaignString(recipient.nameEncrypted) : null,
        unsubscribeToken: decryptCampaignString(recipient.unsubscribeTokenEncrypted),
      }))
      let accepted = 0
      let unknown = 0
      const provider = selectedCampaignProvider(campaign.provider)
      let phase = provider === "resend" ? "syncing_contacts" : "sending_bulk"

      if (provider === "ses") {
        const results = yield* attempt("admin.email-campaigns.send.ses-bulk", async () => {
          try {
            return await deliverSesCampaignBatch({
              fromAddress: selectedCampaignFromAddress(campaign.fromAddress),
              subject: campaign.subject,
              previewText: campaign.previewText ?? undefined,
              bodyText: campaign.bodyText,
              visibleUnsubscribe: campaign.visibleUnsubscribe,
              recipients: bulkRecipients,
            })
          } catch {
            if (claimed.length > 0) {
              await db.update(emailCampaignRecipients).set({
                status: "unknown",
                provider: "ses",
                contactedAt: new Date(),
              }).where(inArray(emailCampaignRecipients.id, claimed.map(({ id }) => id)))
            }
            return bulkRecipients.map(({ id }) => ({ id, accepted: false, messageId: null }))
          }
        })
        for (const result of results) {
          yield* attempt("admin.email-campaigns.send.ses-result", () =>
            db.update(emailCampaignRecipients).set({
              status: result.accepted ? "provider_accepted" : "unknown",
              provider: "ses",
              providerMessageId: result.messageId,
              contactedAt: new Date(),
            }).where(eq(emailCampaignRecipients.id, result.id)),
          )
          if (result.accepted) accepted += 1
          else unknown += 1
        }
      } else {
        let segmentId = campaign.providerSegmentId
        if (segmentId === "__creating__") {
          yield* attempt("admin.email-campaigns.send.resend-release-busy", () =>
            db.update(emailCampaignRecipients).set({ status: "pending" }).where(
              inArray(emailCampaignRecipients.id, claimed.map(({ id }) => id)),
            ),
          )
          return yield* reject(400, "campaign_busy")
        }
        if (!segmentId) {
          const claimedSegmentSetup = yield* attempt("admin.email-campaigns.send.resend-segment.claim", async () =>
            (await db.update(emailCampaigns).set({ providerSegmentId: "__creating__" }).where(and(
              eq(emailCampaigns.id, campaignId),
              isNull(emailCampaigns.providerSegmentId),
            )).returning({ id: emailCampaigns.id }))[0],
          )
          if (!claimedSegmentSetup) {
            yield* attempt("admin.email-campaigns.send.resend-release-race", () =>
              db.update(emailCampaignRecipients).set({ status: "pending" }).where(
                inArray(emailCampaignRecipients.id, claimed.map(({ id }) => id)),
              ),
            )
            return yield* reject(400, "campaign_busy")
          }
          segmentId = yield* attempt("admin.email-campaigns.send.resend-segment", async () => {
            try {
              const createdSegmentId = await createResendCampaignSegment(campaign.name)
              await db.update(emailCampaigns).set({ providerSegmentId: createdSegmentId }).where(and(
                eq(emailCampaigns.id, campaignId),
                eq(emailCampaigns.providerSegmentId, "__creating__"),
              ))
              return createdSegmentId
            } catch (error) {
              await db.update(emailCampaigns).set({ providerSegmentId: null }).where(and(
                eq(emailCampaigns.id, campaignId),
                eq(emailCampaigns.providerSegmentId, "__creating__"),
              ))
              await db.update(emailCampaignRecipients).set({ status: "pending" }).where(
                inArray(emailCampaignRecipients.id, claimed.map(({ id }) => id)),
              )
              throw error
            }
          })
        }
        const results = yield* attempt("admin.email-campaigns.send.resend-sync", () =>
          syncResendCampaignRecipients(bulkRecipients, segmentId),
        )
        for (const result of results) {
          yield* attempt("admin.email-campaigns.send.resend-sync-result", () =>
            db.update(emailCampaignRecipients).set({
              status: result.accepted ? "provider_synced" : "pending",
              provider: result.accepted ? "resend" : null,
            }).where(eq(emailCampaignRecipients.id, result.id)),
          )
          if (result.accepted) accepted += 1
        }
      }

      const progressRows = yield* attempt("admin.email-campaigns.send.progress", () =>
        db.select({
          pending: sql<number>`count(*) filter (where ${emailCampaignRecipients.status} = 'pending')::int`,
          sending: sql<number>`count(*) filter (where ${emailCampaignRecipients.status} = 'sending')::int`,
          synced: sql<number>`count(*) filter (where ${emailCampaignRecipients.status} = 'provider_synced')::int`,
        }).from(emailCampaignRecipients).where(
          eq(emailCampaignRecipients.campaignId, campaignId),
        ),
      )
      const pending = progressRows[0]?.pending ?? 0
      const sending = progressRows[0]?.sending ?? 0
      const latestCampaign = yield* attempt("admin.email-campaigns.send.latest-status", async () =>
        (await db.select({ status: emailCampaigns.status }).from(emailCampaigns).where(eq(emailCampaigns.id, campaignId)).limit(1))[0],
      )
      let status = pending + sending === 0 && provider === "ses"
        ? "completed"
        : latestCampaign?.status === "paused"
          ? "paused"
          : "sending"

      if (
        provider === "resend" &&
        pending + sending === 0 &&
        latestCampaign?.status !== "paused"
      ) {
        const currentBeforeSuppression = yield* attempt("admin.email-campaigns.send.resend-current-before-suppression", async () =>
          (await db.select().from(emailCampaigns).where(eq(emailCampaigns.id, campaignId)).limit(1))[0],
        )
        const newlySuppressed = yield* attempt("admin.email-campaigns.send.resend-late-suppressions", async () => {
          const rows = await db.select().from(emailCampaignRecipients).where(and(
            eq(emailCampaignRecipients.campaignId, campaignId),
            eq(emailCampaignRecipients.status, "provider_synced"),
            inArray(
              emailCampaignRecipients.emailKey,
              db.select({ emailKey: emailSuppressions.emailKey }).from(emailSuppressions),
            ),
          ))
          return rows
        })
        const suppressionSegmentId = currentBeforeSuppression?.providerSegmentId
        if (newlySuppressed.length > 0 && suppressionSegmentId) {
          yield* attempt("admin.email-campaigns.send.resend-remove-suppressed", () =>
            removeResendCampaignRecipients(newlySuppressed.map((recipient) => ({
              id: recipient.id,
              email: decryptCampaignString(recipient.emailEncrypted),
              name: recipient.nameEncrypted ? decryptCampaignString(recipient.nameEncrypted) : null,
              unsubscribeToken: decryptCampaignString(recipient.unsubscribeTokenEncrypted),
            })), suppressionSegmentId),
          )
          yield* attempt("admin.email-campaigns.send.resend-mark-suppressed", () =>
            db.update(emailCampaignRecipients).set({ status: "suppressed" }).where(
              inArray(emailCampaignRecipients.id, newlySuppressed.map(({ id }) => id)),
            ),
          )
        }

        const current = yield* attempt("admin.email-campaigns.send.resend-current", async () =>
          (await db.select().from(emailCampaigns).where(eq(emailCampaigns.id, campaignId)).limit(1))[0],
        )
        if (current?.status !== "paused" && current?.providerSegmentId) {
          let providerCampaignState = current.providerCampaignId
          if (providerCampaignState === "__creating__" || providerCampaignState?.startsWith("sending:")) {
            return yield* reject(400, "campaign_busy")
          }
          if (!providerCampaignState) {
            const claimedBroadcastSetup = yield* attempt("admin.email-campaigns.send.resend-broadcast.claim-create", async () =>
              (await db.update(emailCampaigns).set({ providerCampaignId: "__creating__" }).where(and(
                eq(emailCampaigns.id, campaignId),
                isNull(emailCampaigns.providerCampaignId),
              )).returning({ id: emailCampaigns.id }))[0],
            )
            if (!claimedBroadcastSetup) return yield* reject(400, "campaign_busy")
            providerCampaignState = yield* attempt("admin.email-campaigns.send.resend-broadcast.create", async () => {
              try {
                const createdBroadcastId = await createResendBroadcast({
                  campaignName: current.name,
                  fromAddress: selectedCampaignFromAddress(current.fromAddress),
                  segmentId: current.providerSegmentId!,
                  subject: current.subject,
                  previewText: current.previewText ?? undefined,
                  bodyText: current.bodyText,
                  visibleUnsubscribe: current.visibleUnsubscribe,
                })
                const draftState = `draft:${createdBroadcastId}`
                await db.update(emailCampaigns).set({ providerCampaignId: draftState }).where(and(
                  eq(emailCampaigns.id, campaignId),
                  eq(emailCampaigns.providerCampaignId, "__creating__"),
                ))
                return draftState
              } catch (error) {
                await db.update(emailCampaigns).set({ providerCampaignId: null }).where(and(
                  eq(emailCampaigns.id, campaignId),
                  eq(emailCampaigns.providerCampaignId, "__creating__"),
                ))
                throw error
              }
            })
          }
          const broadcastId = providerCampaignState.replace(/^(draft|sent):/, "")
          if (!providerCampaignState.startsWith("sent:")) {
            const sendingState = `sending:${broadcastId}`
            const claimedBroadcastSend = yield* attempt("admin.email-campaigns.send.resend-broadcast.claim-send", async () =>
              (await db.update(emailCampaigns).set({ providerCampaignId: sendingState }).where(and(
                eq(emailCampaigns.id, campaignId),
                eq(emailCampaigns.providerCampaignId, providerCampaignState),
              )).returning({ id: emailCampaigns.id }))[0],
            )
            if (!claimedBroadcastSend) return yield* reject(400, "campaign_busy")
            yield* attempt("admin.email-campaigns.send.resend-broadcast.send", async () => {
              try {
                await sendResendBroadcast(broadcastId)
                await db.update(emailCampaigns).set({ providerCampaignId: `sent:${broadcastId}` }).where(and(
                  eq(emailCampaigns.id, campaignId),
                  eq(emailCampaigns.providerCampaignId, sendingState),
                ))
              } catch (error) {
                await db.update(emailCampaigns).set({ providerCampaignId: `draft:${broadcastId}` }).where(and(
                  eq(emailCampaigns.id, campaignId),
                  eq(emailCampaigns.providerCampaignId, sendingState),
                ))
                throw error
              }
            })
          }
          yield* attempt("admin.email-campaigns.send.resend-broadcast.accepted", () =>
            db.update(emailCampaignRecipients).set({
              status: "provider_accepted",
              provider: "resend",
              providerMessageId: broadcastId,
              contactedAt: new Date(),
            }).where(and(
              eq(emailCampaignRecipients.campaignId, campaignId),
              eq(emailCampaignRecipients.status, "provider_synced"),
            )),
          )
          status = "completed"
          phase = "broadcast_sent"
        } else {
          status = "paused"
          phase = "ready_to_broadcast"
        }
      }
      yield* attempt("admin.email-campaigns.send.finish", () =>
        db.update(emailCampaigns).set({
          status,
          completedAt: status === "completed" ? new Date() : null,
        }).where(eq(emailCampaigns.id, campaignId)),
      )
      yield* attempt("admin.email-campaigns.send.notify", () =>
        notifyAdminAction({
          actionTaken: `Sent email campaign ${campaignId} batch (${claimed.length} attempted)`,
          actorEmail: session.email,
          request,
        }),
      )
      return jsonResult({
        ok: true as const,
        attempted: claimed.length,
        accepted,
        unknown,
        pending,
        status,
        phase,
      })
    })

const pauseEmailCampaignOperation: AdminOperationsShape["pauseEmailCampaign"] =
  (campaignId, session, request) =>
    Effect.gen(function* () {
      if (!Number.isSafeInteger(campaignId) || campaignId <= 0) return yield* reject(400, "invalid_campaign")
      const updated = yield* attempt("admin.email-campaigns.pause", async () =>
        (await db.update(emailCampaigns).set({ status: "paused" }).where(and(
          eq(emailCampaigns.id, campaignId),
          inArray(emailCampaigns.status, ["frozen", "sending"]),
        )).returning({ id: emailCampaigns.id }))[0],
      )
      if (!updated) return yield* reject(404, "not_found")
      yield* attempt("admin.email-campaigns.pause.notify", () =>
        notifyAdminAction({
          actionTaken: `Paused email campaign ${campaignId}`,
          actorEmail: session.email,
          request,
        }),
      )
      return jsonResult({ ok: true as const })
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
    emailCampaigns: emailCampaignsOperation,
    emailProviderStatus: emailProviderStatusOperation,
    previewEmailCampaign: previewEmailCampaignOperation,
    createEmailCampaign: createEmailCampaignOperation,
    testEmailCampaign: testEmailCampaignOperation,
    sendEmailCampaign: sendEmailCampaignOperation,
    pauseEmailCampaign: pauseEmailCampaignOperation,
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
