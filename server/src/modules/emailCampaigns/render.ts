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

export type CampaignBodyValidationError =
  | "campaign_image_alt_required"
  | "campaign_image_requires_https"
  | "campaign_image_syntax_unsupported"
  | "too_many_campaign_images"

const BASIC_MARKDOWN_IMAGE = /!\[([^\]\n]*)\]\(([^)\s]+)\)/g

export const validateCampaignBodyImages = (
  bodyText: string,
): CampaignBodyValidationError | null => {
  const imageStarts = bodyText.match(/!\[/g)?.length ?? 0
  if (imageStarts === 0) return null

  const images = [...bodyText.matchAll(BASIC_MARKDOWN_IMAGE)]
  if (images.length !== imageStarts) return "campaign_image_syntax_unsupported"
  if (images.length > 10) return "too_many_campaign_images"

  for (const image of images) {
    if (!image[1]?.trim()) return "campaign_image_alt_required"
    try {
      const url = new URL(image[2] ?? "")
      if (url.protocol !== "https:" || url.username || url.password) {
        return "campaign_image_requires_https"
      }
    } catch {
      return "campaign_image_requires_https"
    }
  }
  return null
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
  const bodyValidationError = validateCampaignBodyImages(input.bodyText)
  if (bodyValidationError) throw new Error(bodyValidationError)
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
  const textElement = React.createElement(CampaignEmail, {
    markdown: markdown.replace(
      BASIC_MARKDOWN_IMAGE,
      (_match, alt: string, url: string) => `${alt}: ${url}`,
    ),
    previewText,
    unsubscribeUrl,
    visibleUnsubscribe: input.visibleUnsubscribe,
  })
  const [html, text] = await Promise.all([
    render(element),
    render(textElement, { plainText: true }),
  ])
  return { subject, html, text, unsubscribeUrl }
}
