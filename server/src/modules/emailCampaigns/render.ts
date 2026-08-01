import { CampaignEmail } from "@inline-chat/email-templates"
import { render } from "@react-email/render"
import * as React from "react"
import { API_BASE_URL } from "@in/server/env"

export interface CampaignTemplateVariables {
  readonly name?: string | undefined
  readonly email?: string | undefined
}

export interface RenderCampaignInput {
  readonly subject: string
  readonly bodyText: string
  readonly previewText?: string | undefined
  readonly variables: CampaignTemplateVariables
  readonly unsubscribeToken?: string | undefined
  readonly unsubscribeUrl?: string | undefined
  readonly visibleUnsubscribe: boolean
}

export interface RenderedCampaign {
  readonly subject: string
  readonly html: string
  readonly text: string
  readonly unsubscribeUrl?: string | undefined
}

const variableValue = (key: string, variables: CampaignTemplateVariables): string => {
  if (key === "name" || key === "first_name") return variables.name?.trim() || "there"
  if (key === "email") return variables.email?.trim() || "preview@inline.chat"
  return `{{${key}}}`
}

export const interpolateCampaignVariables = (
  value: string,
  variables: CampaignTemplateVariables,
): string => value
  .replaceAll("<name>", "{{name}}")
  .replace(/\{\{\s*(name|first_name|email)\s*\}\}/g, (_match, key: string) =>
    variableValue(key, variables))

const escapeMarkdownHtml = (value: string): string => value
  .replaceAll("&", "&amp;")
  .replaceAll("<", "&lt;")
  .replaceAll(">", "&gt;")

export const campaignUnsubscribeUrl = (token: string): string =>
  `${API_BASE_URL}/email/unsubscribe/${encodeURIComponent(token)}`

export const renderCampaign = async (input: RenderCampaignInput): Promise<RenderedCampaign> => {
  const subject = interpolateCampaignVariables(input.subject, input.variables)
  const markdown = escapeMarkdownHtml(
    interpolateCampaignVariables(input.bodyText.trim(), input.variables),
  )
  const previewText = input.previewText
    ? interpolateCampaignVariables(input.previewText, input.variables)
    : undefined
  const unsubscribeUrl = input.unsubscribeUrl ?? (
    input.unsubscribeToken ? campaignUnsubscribeUrl(input.unsubscribeToken) : undefined
  )
  const element = React.createElement(CampaignEmail, {
    markdown,
    previewText,
    unsubscribeUrl,
    visibleUnsubscribe: input.visibleUnsubscribe,
  })
  const [html, text] = await Promise.all([
    render(element),
    render(element, { plainText: true }),
  ])
  return { subject, html, text, unsubscribeUrl }
}
