import type { User } from "@inline/client/core"
import type { InlineMediaRepository } from "./InlineMediaRepository"

export type InlineMediaDescriptor = {
  key: string
}

export const inlineAvatarMediaDescriptor = (
  user?: User,
): InlineMediaDescriptor | undefined => {
  const key =
    user?.profilePhoto?.fileUniqueId ??
    user?.profilePhoto?.cdnUrl
  return key ? { key } : undefined
}

export const promoteInlineFirstFrameMedia = async (
  repository: InlineMediaRepository,
  descriptors: readonly (InlineMediaDescriptor | undefined)[],
) => {
  const keys = [
    ...new Set(
      descriptors
        .map((descriptor) => descriptor?.key)
        .filter((key): key is string => Boolean(key)),
    ),
  ]
  const results = await Promise.allSettled(
    keys.map((key) => repository.promoteCached(key)),
  )
  return results.reduce(
    (count, result) =>
      count +
      (result.status === "fulfilled" && result.value ? 1 : 0),
    0,
  )
}
