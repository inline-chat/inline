import { describe, expect, it } from "bun:test"
import { existsSync, readFileSync } from "node:fs"
import { join } from "node:path"
import { fileURLToPath } from "node:url"

type JournalEntry = {
  idx: number
  tag: string
}

type DrizzleSnapshot = {
  tables: Record<
    string,
    {
      columns: Record<string, unknown>
      indexes?: Record<string, unknown>
      foreignKeys?: Record<string, { onDelete?: string; tableFrom?: string; tableTo?: string }>
    }
  >
}

const serverRoot = fileURLToPath(new URL("../../", import.meta.url))
const drizzleDir = join(serverRoot, "drizzle")

const richMigrationTags = [
  "0088_add-message-rich-text",
  "0089_rich-message-media-index",
  "0090_rich-media-public-url-failures",
] as const

describe("rich text migrations", () => {
  it("keeps the rich text migrations in contiguous journal order", () => {
    const journal = readJson<{ entries: JournalEntry[] }>("meta/_journal.json")
    const entries = journal.entries
    const tags = entries.map((entry) => entry.tag)

    expect(new Set(tags).size).toBe(tags.length)
    expect(new Set(entries.map((entry) => entry.idx)).size).toBe(entries.length)

    for (let index = 1; index < entries.length; index += 1) {
      expect(entries[index]!.idx).toBeGreaterThan(entries[index - 1]!.idx)
    }

    for (const tag of richMigrationTags) {
      const expectedIdx = Number(tag.slice(0, 4))
      const entry = entries.find((item) => item.tag === tag)
      expect(entry?.idx).toBe(expectedIdx)
      expect(existsSync(join(drizzleDir, `${tag}.sql`))).toBe(true)
    }

    const richIndexes = richMigrationTags.map((tag) => tags.indexOf(tag))
    expect(richIndexes).toEqual([88, 89, 90])
  })

  it("locks the critical rich text migration DDL", () => {
    const richTextSql = readMigration("0088_add-message-rich-text")
    expect(richTextSql).toContain('ALTER TABLE "messages" ADD COLUMN "rich_text_encrypted" "bytea"')
    expect(richTextSql).toContain('ALTER TABLE "messages" ADD COLUMN "rich_text_iv" "bytea"')
    expect(richTextSql).toContain('ALTER TABLE "messages" ADD COLUMN "rich_text_tag" "bytea"')

    const mediaSql = readMigration("0089_rich-message-media-index")
    expect(mediaSql).toContain('CREATE TABLE "message_rich_media"')
    for (const column of [
      "message_global_id",
      "chat_id",
      "message_id",
      "block_id",
      "block_path",
      "sort_order",
      "kind",
      "status",
      "photo_id",
      "video_id",
      "document_id",
      "voice_id",
      "public_url_hash",
      "public_url",
      "public_url_iv",
      "public_url_tag",
    ]) {
      expect(mediaSql).toContain(`"${column}"`)
    }
    expect(mediaSql).toContain('REFERENCES "public"."messages"("global_id") ON DELETE cascade')
    expect(mediaSql).toContain('REFERENCES "public"."chats"("id") ON DELETE cascade')
    expect(mediaSql).toContain('CREATE INDEX "message_rich_media_message_idx"')
    expect(mediaSql).toContain('CREATE INDEX "message_rich_media_chat_message_idx"')
    expect(mediaSql).toContain('CREATE INDEX "message_rich_media_voice_idx"')
    expect(mediaSql).toContain('CREATE INDEX "message_rich_media_public_url_hash_idx"')

    const failureSql = readMigration("0090_rich-media-public-url-failures")
    expect(failureSql).toContain('CREATE TABLE "rich_media_public_url_failures"')
    for (const column of ["kind", "url_hash", "url_host", "failure_count", "last_error", "retry_after"]) {
      expect(failureSql).toContain(`"${column}"`)
    }
    expect(failureSql).toContain(
      'CREATE UNIQUE INDEX "rich_media_public_url_failures_kind_url_hash_unique" ON "rich_media_public_url_failures" USING btree ("kind","url_hash")',
    )
    expect(failureSql).toContain('CREATE INDEX "rich_media_public_url_failures_retry_after_idx"')
    expect(failureSql).toContain('CREATE INDEX "rich_media_public_url_failures_url_host_idx"')
  })

  it("keeps the latest Drizzle snapshot aligned with rich text schema", () => {
    const snapshot = readJson<DrizzleSnapshot>("meta/0090_snapshot.json")
    const messages = snapshot.tables["public.messages"]
    expect(messages).toBeDefined()
    expect(messages!.columns["rich_text_encrypted"]).toBeDefined()
    expect(messages!.columns["rich_text_iv"]).toBeDefined()
    expect(messages!.columns["rich_text_tag"]).toBeDefined()

    const media = snapshot.tables["public.message_rich_media"]
    expect(media).toBeDefined()
    for (const column of [
      "message_global_id",
      "chat_id",
      "message_id",
      "block_id",
      "block_path",
      "sort_order",
      "kind",
      "status",
      "photo_id",
      "video_id",
      "document_id",
      "voice_id",
      "public_url_hash",
      "public_url",
      "public_url_iv",
      "public_url_tag",
    ]) {
      expect(media!.columns[column]).toBeDefined()
    }
    expect(media!.indexes?.["message_rich_media_message_idx"]).toBeDefined()
    expect(media!.indexes?.["message_rich_media_chat_message_idx"]).toBeDefined()
    expect(media!.indexes?.["message_rich_media_voice_idx"]).toBeDefined()
    expect(media!.indexes?.["message_rich_media_public_url_hash_idx"]).toBeDefined()
    expect(media!.foreignKeys?.["message_rich_media_message_global_id_messages_global_id_fk"]?.onDelete).toBe("cascade")
    expect(media!.foreignKeys?.["message_rich_media_chat_id_chats_id_fk"]?.onDelete).toBe("cascade")

    const failures = snapshot.tables["public.rich_media_public_url_failures"]
    expect(failures).toBeDefined()
    for (const column of ["kind", "url_hash", "url_host", "failure_count", "last_error", "retry_after"]) {
      expect(failures!.columns[column]).toBeDefined()
    }
    expect(failures!.indexes?.["rich_media_public_url_failures_kind_url_hash_unique"]).toBeDefined()
    expect(failures!.indexes?.["rich_media_public_url_failures_retry_after_idx"]).toBeDefined()
    expect(failures!.indexes?.["rich_media_public_url_failures_url_host_idx"]).toBeDefined()
  })
})

function readMigration(tag: (typeof richMigrationTags)[number]) {
  return readText(`${tag}.sql`)
}

function readJson<T>(relativePath: string): T {
  return JSON.parse(readText(relativePath)) as T
}

function readText(relativePath: string) {
  return readFileSync(join(drizzleDir, relativePath), "utf8")
}
