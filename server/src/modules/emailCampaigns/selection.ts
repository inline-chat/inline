import { createHash } from "node:crypto"
import type {
  EmailCampaignSelectionOrder,
  ResolvedCampaignRecipient,
} from "./types"

const deterministicRank = (emailKey: string, seed: string): string =>
  createHash("sha256").update(`${seed}:${emailKey}`).digest("hex")

const compareJoinDates = (
  left: ResolvedCampaignRecipient,
  right: ResolvedCampaignRecipient,
  direction: "newest" | "oldest",
): number => {
  const leftTime = left.joinedAt?.getTime()
  const rightTime = right.joinedAt?.getTime()
  if (leftTime === undefined && rightTime !== undefined) return 1
  if (leftTime !== undefined && rightTime === undefined) return -1
  if (leftTime !== undefined && rightTime !== undefined && leftTime !== rightTime) {
    return direction === "newest" ? rightTime - leftTime : leftTime - rightTime
  }
  return left.emailKey.localeCompare(right.emailKey)
}

export const orderCampaignRecipients = (
  recipients: readonly ResolvedCampaignRecipient[],
  order: EmailCampaignSelectionOrder,
  sampleSeed: string,
): readonly ResolvedCampaignRecipient[] => {
  const selected = [...recipients]
  if (order === "newest" || order === "oldest") {
    return selected.sort((left, right) => compareJoinDates(left, right, order))
  }
  return selected.sort((left, right) =>
    deterministicRank(left.emailKey, sampleSeed).localeCompare(
      deterministicRank(right.emailKey, sampleSeed),
    ))
}
