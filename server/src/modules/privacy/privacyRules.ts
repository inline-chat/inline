import {
  defaultPrivacySettings,
  PrivacyRuleSchema,
  type PrivacyRule,
  type PrivacyRuleInput,
  type UserSettingsGeneral,
} from "@in/server/db/models/userSettings/types"

type StoredPrivacy = UserSettingsGeneral["privacy"]

export type PrivacyPatch = {
  shareTimeZone?: boolean
  appearInGlobalSearch?: boolean
  timeZone?: PrivacyRuleInput
}

/** Whether `viewerId` may see what `rule` protects for `ownerId`. */
export const canSeeWithRule = (rule: PrivacyRule, ownerId: number, viewerId: number): boolean => {
  if (viewerId === ownerId) return true
  if (rule.audience === "everyone") return !rule.neverShare.includes(viewerId)
  return rule.alwaysShare.includes(viewerId)
}

/** True when every viewer passes, so a viewer-blind path may show the value. */
export const isPublicRule = (rule: PrivacyRule): boolean =>
  rule.audience === "everyone" && rule.neverShare.length === 0

/** The legacy share_time_zone flag older clients read and write. */
export const legacyShareFlag = (rule: PrivacyRule): boolean => rule.audience === "everyone"

export const ruleFromLegacyShare = (share: boolean): PrivacyRule => ({
  audience: share ? "everyone" : "nobody",
  alwaysShare: [],
  neverShare: [],
})

export const effectiveTimeZoneRule = (privacy: Pick<StoredPrivacy, "shareTimeZone" | "timeZone">): PrivacyRule =>
  privacy.timeZone ?? ruleFromLegacyShare(privacy.shareTimeZone)

const uniqueTargets = (ids: number[], ownerId: number): number[] => {
  const seen = new Set<number>()
  return ids.filter((id) => {
    if (id === ownerId || seen.has(id)) return false
    seen.add(id)
    return true
  })
}

export const normalizePrivacyRule = (input: PrivacyRuleInput, ownerId: number): PrivacyRule => {
  const rule = PrivacyRuleSchema.parse(input)
  return {
    audience: rule.audience,
    alwaysShare: uniqueTargets(rule.alwaysShare, ownerId),
    neverShare: uniqueTargets(rule.neverShare, ownerId),
  }
}

/**
 * Applies a privacy patch while keeping share_time_zone and the time zone rule
 * in step. A rule wins over the flag. Older clients resend the flag with every
 * save, so the flag changes the audience only when it disagrees with the
 * current rule, and the exception lists survive that change.
 */
export const mergePrivacyPatch = (
  current: StoredPrivacy | undefined,
  patch: PrivacyPatch | undefined,
  ownerId: number,
): StoredPrivacy => {
  const base: StoredPrivacy = current ?? { ...defaultPrivacySettings }
  const currentRule = effectiveTimeZoneRule(base)

  let timeZone = currentRule
  if (patch?.timeZone) {
    timeZone = normalizePrivacyRule(patch.timeZone, ownerId)
  } else if (patch?.shareTimeZone !== undefined && patch.shareTimeZone !== legacyShareFlag(currentRule)) {
    timeZone = { ...currentRule, audience: patch.shareTimeZone ? "everyone" : "nobody" }
  }

  return {
    appearInGlobalSearch: patch?.appearInGlobalSearch ?? base.appearInGlobalSearch,
    shareTimeZone: legacyShareFlag(timeZone),
    // Keep legacy rows rule-free until the rule actually changes.
    ...(base.timeZone || timeZone !== currentRule ? { timeZone } : {}),
  }
}
