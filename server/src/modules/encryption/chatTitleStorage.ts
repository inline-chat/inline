import { and, eq, isNull, or, sql } from "drizzle-orm"
import { chats } from "../../db/schema/chats"
import { contentEncryptionWritesEnabled, contentLookup } from "./contentEncryption"

type Scope = { spaceId: number | null; createdBy?: number | null }

// Match the existing SQL trim (ASCII spaces), while retaining display casing.
export const normalizeStoredTitle = (title: string) => title.replace(/^ +| +$/g, "").toLowerCase()

export const chatTitleHash = (title: string, scope: Scope): Buffer => contentLookup(
  "chat-title", scope.spaceId === null ? ["home", scope.createdBy ?? 0] : ["space", scope.spaceId],
  normalizeStoredTitle(title),
)

export const chatTitleFields = (title: string | null, scope: Scope) => ({
  title, titleHash: title === null || !contentEncryptionWritesEnabled() ? null : chatTitleHash(title, scope),
})

/** Legacy rows are matched only until the bounded backfill has populated their index. */
export const chatTitleMatches = (title: string, scope: Scope) => and(
  scope.spaceId === null
    ? and(isNull(chats.spaceId), eq(chats.createdBy, scope.createdBy ?? 0))
    : eq(chats.spaceId, scope.spaceId),
  or(
    eq(chats.titleHash, chatTitleHash(title, scope)),
    and(isNull(chats.titleHash), sql`lower(trim(${chats.title})) = ${normalizeStoredTitle(title)}`),
  ),
)
