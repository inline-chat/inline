import { describe, expect, test } from "bun:test"
import {
  canSeeWithRule,
  effectiveTimeZoneRule,
  isPublicRule,
  mergePrivacyPatch,
} from "@in/server/modules/privacy/privacyRules"

const owner = 1

describe("privacy rules", () => {
  test("exceptions apply only to their audience and the owner always sees", () => {
    const nobody = { audience: "nobody" as const, alwaysShare: [2], neverShare: [3] }
    expect(canSeeWithRule(nobody, owner, owner)).toBe(true)
    expect(canSeeWithRule(nobody, owner, 2)).toBe(true)
    expect(canSeeWithRule(nobody, owner, 4)).toBe(false)

    const everyone = { audience: "everyone" as const, alwaysShare: [2], neverShare: [3] }
    expect(canSeeWithRule(everyone, owner, 3)).toBe(false)
    expect(canSeeWithRule(everyone, owner, 4)).toBe(true)
    expect(isPublicRule(everyone)).toBe(false)
    expect(isPublicRule({ ...everyone, neverShare: [] })).toBe(true)
  })

  test("legacy rows derive the rule from share_time_zone and stay rule-free", () => {
    const legacy = { shareTimeZone: false, appearInGlobalSearch: true }
    expect(effectiveTimeZoneRule(legacy)).toEqual({ audience: "nobody", alwaysShare: [], neverShare: [] })
    expect(mergePrivacyPatch(legacy, { appearInGlobalSearch: false, shareTimeZone: false }, owner)).toEqual({
      shareTimeZone: false,
      appearInGlobalSearch: false,
    })
  })

  test("a rule wins over the flag and is deduplicated without the owner", () => {
    const merged = mergePrivacyPatch(
      undefined,
      { shareTimeZone: true, timeZone: { audience: "nobody", alwaysShare: [2, owner, 2, 5] } },
      owner,
    )
    expect(merged.shareTimeZone).toBe(false)
    expect(merged.timeZone).toEqual({ audience: "nobody", alwaysShare: [2, 5], neverShare: [] })
  })

  test("an older client's resent flag keeps the lists; a flipped flag changes only the audience", () => {
    const current = {
      shareTimeZone: false,
      appearInGlobalSearch: true,
      timeZone: { audience: "nobody" as const, alwaysShare: [2], neverShare: [3] },
    }
    expect(mergePrivacyPatch(current, { shareTimeZone: false, appearInGlobalSearch: false }, owner)).toEqual({
      ...current,
      appearInGlobalSearch: false,
    })
    expect(mergePrivacyPatch(current, { shareTimeZone: true }, owner).timeZone).toEqual({
      audience: "everyone",
      alwaysShare: [2],
      neverShare: [3],
    })
  })
})
