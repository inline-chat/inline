import {
  SendBulkEmailCommand,
  SendEmailCommand,
  type SendBulkEmailCommandInput,
  type SendEmailCommandInput,
} from "@aws-sdk/client-sesv2"
import { API_BASE_URL, SEND_EMAIL, isProd } from "@in/server/env"
import { resend } from "@in/server/libs/resend"
import { sesClient } from "@in/server/libs/ses"
import { interpolateCampaignVariables, renderCampaign } from "./render"

export interface CampaignDeliveryInput {
  readonly provider: "resend" | "ses"
  readonly fromAddress: CampaignFromAddress
  readonly to: string
  readonly name?: string | undefined
  readonly subject: string
  readonly previewText?: string | undefined
  readonly bodyText: string
  readonly unsubscribeToken: string
  readonly visibleUnsubscribe: boolean
}

export type CampaignFromAddress =
  | "team@inline.chat"
  | "founders@inline.chat"
  | "mo@inline.chat"

const campaignFromHeader = (fromAddress: CampaignFromAddress): string =>
  `Inline <${fromAddress}>`

export interface CampaignBulkRecipient {
  readonly id: number
  readonly email: string
  readonly name: string | null
  readonly unsubscribeToken: string
}

export interface CampaignDeliveryResult {
  readonly provider: "ses" | "resend" | "preview"
  readonly messageId: string | null
}

export interface BulkRecipientResult {
  readonly id: number
  readonly accepted: boolean
  readonly messageId: string | null
}

const listHeaders = (url: string) => ({
  "List-Unsubscribe": `<${url}>`,
  "List-Unsubscribe-Post": "List-Unsubscribe=One-Click",
})

const waitForResendRequestSlot = async (): Promise<void> => {
  await new Promise((resolve) => setTimeout(resolve, 220))
}

export const deliverCampaignTestEmail = async (
  input: CampaignDeliveryInput,
): Promise<CampaignDeliveryResult> => {
  if (!isProd && !SEND_EMAIL) return { provider: "preview", messageId: null }

  const rendered = await renderCampaign({
    ...input,
    variables: { name: input.name, email: input.to },
  })
  if (!rendered.unsubscribeUrl) throw new Error("Campaign unsubscribe URL was not rendered")
  const headers = listHeaders(rendered.unsubscribeUrl)

  if (input.provider === "ses") {
    const sesInput: SendEmailCommandInput = {
      Content: {
        Simple: {
          Subject: { Data: rendered.subject },
          Body: {
            Html: { Data: rendered.html },
            Text: { Data: rendered.text },
          },
          Headers: Object.entries(headers).map(([Name, Value]) => ({ Name, Value })),
        },
      },
      FromEmailAddress: campaignFromHeader(input.fromAddress),
      Destination: { ToAddresses: [input.to] },
      ReplyToAddresses: ["founders@inline.chat"],
    }
    const result = await sesClient.send(new SendEmailCommand(sesInput))
    return { provider: "ses", messageId: result.MessageId ?? null }
  }

  const result = await resend.emails.send({
    from: campaignFromHeader(input.fromAddress),
    to: input.to,
    subject: rendered.subject,
    text: rendered.text,
    html: rendered.html,
    replyTo: "founders@inline.chat",
    headers,
  })
  if (result.error) throw result.error
  return { provider: "resend", messageId: result.data?.id ?? null }
}

const resendContact = async (
  recipient: CampaignBulkRecipient,
  segmentId: string,
): Promise<void> => {
  await waitForResendRequestSlot()
  const existing = await resend.contacts.get({ email: recipient.email })
  if (existing.data) {
    await waitForResendRequestSlot()
    const updated = await resend.contacts.update({
      email: recipient.email,
      firstName: recipient.name,
    })
    if (updated.error) throw updated.error
    await waitForResendRequestSlot()
    const added = await resend.contacts.segments.add({ email: recipient.email, segmentId })
    if (added.error) throw added.error
    return
  }
  await waitForResendRequestSlot()
  const created = await resend.contacts.create({
    email: recipient.email,
    firstName: recipient.name ?? undefined,
    segments: [{ id: segmentId }],
  })
  if (created.error) throw created.error
}

export const createResendCampaignSegment = async (campaignName: string): Promise<string> => {
  if (!isProd && !SEND_EMAIL) return "preview-segment"
  const result = await resend.segments.create({ name: `Inline campaign: ${campaignName}` })
  if (result.error || !result.data) throw result.error ?? new Error("Resend did not return a segment")
  return result.data.id
}

export const syncResendCampaignRecipients = async (
  recipients: readonly CampaignBulkRecipient[],
  segmentId: string,
): Promise<readonly BulkRecipientResult[]> => {
  if (!isProd && !SEND_EMAIL) {
    return recipients.map(({ id }) => ({ id, accepted: true, messageId: null }))
  }
  const results: BulkRecipientResult[] = []
  for (const recipient of recipients) {
    try {
      await resendContact(recipient, segmentId)
      results.push({ id: recipient.id, accepted: true, messageId: null })
    } catch {
      results.push({ id: recipient.id, accepted: false, messageId: null })
    }
  }
  return results
}

export const removeResendCampaignRecipients = async (
  recipients: readonly CampaignBulkRecipient[],
  segmentId: string,
): Promise<void> => {
  if (!isProd && !SEND_EMAIL) return
  for (const recipient of recipients) {
    await waitForResendRequestSlot()
    const result = await resend.contacts.segments.remove({ email: recipient.email, segmentId })
    if (result.error) throw result.error
  }
}

export const createResendBroadcast = async (input: {
  readonly campaignName: string
  readonly fromAddress: CampaignFromAddress
  readonly segmentId: string
  readonly subject: string
  readonly previewText?: string | undefined
  readonly bodyText: string
  readonly visibleUnsubscribe: boolean
}): Promise<string> => {
  if (!isProd && !SEND_EMAIL) return "preview-broadcast"
  const variables = {
    name: "{{{contact.first_name|there}}}",
    email: "{{{contact.email}}}",
  }
  const rendered = await renderCampaign({
    subject: input.subject,
    previewText: input.previewText,
    bodyText: input.bodyText,
    variables,
    unsubscribeUrl: "{{{RESEND_UNSUBSCRIBE_URL}}}",
    visibleUnsubscribe: input.visibleUnsubscribe,
  })
  const result = await resend.broadcasts.create({
    segmentId: input.segmentId,
    name: input.campaignName,
    from: campaignFromHeader(input.fromAddress),
    replyTo: "founders@inline.chat",
    subject: rendered.subject,
    previewText: input.previewText
      ? interpolateCampaignVariables(input.previewText, variables)
      : undefined,
    html: rendered.html,
    text: rendered.text,
  })
  if (result.error || !result.data) throw result.error ?? new Error("Resend did not return a broadcast")
  return result.data.id
}

export const sendResendBroadcast = async (broadcastId: string): Promise<void> => {
  if (!isProd && !SEND_EMAIL) return
  const result = await resend.broadcasts.send(broadcastId)
  if (result.error) throw result.error
}

export const deliverSesCampaignBatch = async (input: {
  readonly fromAddress: CampaignFromAddress
  readonly subject: string
  readonly previewText?: string | undefined
  readonly bodyText: string
  readonly visibleUnsubscribe: boolean
  readonly recipients: readonly CampaignBulkRecipient[]
}): Promise<readonly BulkRecipientResult[]> => {
  if (!isProd && !SEND_EMAIL) {
    return input.recipients.map(({ id }) => ({ id, accepted: true, messageId: null }))
  }

  const rendered = await renderCampaign({
    subject: input.subject,
    previewText: input.previewText,
    bodyText: input.bodyText,
    variables: { name: "{{name}}", email: "{{email}}" },
    unsubscribeUrl: "{{unsubscribe_url}}",
    visibleUnsubscribe: input.visibleUnsubscribe,
  })
  const sesInput: SendBulkEmailCommandInput = {
    FromEmailAddress: campaignFromHeader(input.fromAddress),
    ReplyToAddresses: ["founders@inline.chat"],
    DefaultContent: {
      Template: {
        TemplateContent: {
          Subject: rendered.subject,
          Html: rendered.html,
          Text: rendered.text,
        },
        TemplateData: JSON.stringify({ name: "there", email: "", unsubscribe_url: "" }),
        Headers: [
          { Name: "List-Unsubscribe", Value: "<{{unsubscribe_url}}>" },
          { Name: "List-Unsubscribe-Post", Value: "List-Unsubscribe=One-Click" },
        ],
      },
    },
    BulkEmailEntries: input.recipients.map((recipient) => ({
      Destination: { ToAddresses: [recipient.email] },
      ReplacementEmailContent: {
        ReplacementTemplate: {
          ReplacementTemplateData: JSON.stringify({
            name: recipient.name || "there",
            email: recipient.email,
            unsubscribe_url: `${API_BASE_URL}/email/unsubscribe/${encodeURIComponent(recipient.unsubscribeToken)}`,
          }),
        },
      },
    })),
  }
  const response = await sesClient.send(new SendBulkEmailCommand(sesInput))
  return input.recipients.map((recipient, index) => {
    const result = response.BulkEmailEntryResults?.[index]
    return {
      id: recipient.id,
      accepted: result?.Status === "SUCCESS",
      messageId: result?.MessageId ?? null,
    }
  })
}
