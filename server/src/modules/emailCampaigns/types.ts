export const EMAIL_CAMPAIGN_SOURCES = ["inline", "waitlist"] as const
export const EMAIL_CAMPAIGN_PLATFORMS = [
  "ios",
  "macos",
  "web",
  "api",
  "android",
  "windows",
  "linux",
  "cli",
] as const

export type EmailCampaignSource = (typeof EMAIL_CAMPAIGN_SOURCES)[number]
export type EmailCampaignPlatform = (typeof EMAIL_CAMPAIGN_PLATFORMS)[number]
export type EmailCampaignSelectionOrder = "newest" | "oldest" | "random"

export interface EmailCampaignAudience {
  readonly sources: readonly EmailCampaignSource[]
  readonly verifiedOnly: boolean
  readonly platforms: readonly EmailCampaignPlatform[]
  readonly activeWithinDays?: number | undefined
  readonly joinedAfter?: string | undefined
  readonly joinedBefore?: string | undefined
  readonly manualEmails: readonly string[]
  readonly excludeCampaignIds: readonly number[]
  readonly excludeInlineUsers?: boolean | undefined
  readonly limit?: number | undefined
  readonly sampleSeed: string
  readonly selectionOrder?: EmailCampaignSelectionOrder | undefined
}

export interface ResolvedCampaignRecipient {
  readonly email: string
  readonly name: string | null
  readonly emailKey: string
  readonly sources: readonly (EmailCampaignSource | "manual")[]
  readonly joinedAt: Date | null
}

export interface CampaignAudiencePreview {
  readonly recipients: readonly ResolvedCampaignRecipient[]
  readonly excluded: {
    readonly invalid: number
    readonly typo: number
    readonly unverified: number
    readonly inactive: number
    readonly platform: number
    readonly suppressed: number
    readonly priorCampaign: number
    readonly converted: number
    readonly duplicate: number
    readonly limited: number
  }
}
