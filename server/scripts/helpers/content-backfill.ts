import { sql } from "drizzle-orm"
import { db } from "../../src/db"
import {
  CONTENT_PREFIX, contentLookup, isSealedContent, openContent, openContentText, sealContent, sealContentText,
} from "../../src/modules/encryption/contentEncryption"
import { chatTitleHash } from "../../src/modules/encryption/chatTitleStorage"
import { reactionEmojiHash } from "../../src/db/models/reactions"

import { decrypt } from "../../src/modules/encryption/encryption"

type Field = { name: string; purpose: string; binary?: boolean }
type Table = { name: string; id: string; binaryId?: boolean; fields: readonly Field[] }
// Identifiers are an internal allowlist, never supplied by the CLI.
export const contentTables: readonly Table[] = [
  { name: "chats", id: "id", fields: [
    { name: "title", purpose: "chats.title" }, { name: "description", purpose: "chats.description" },
    { name: "emoji", purpose: "chats.emoji" },
  ] },
  { name: "dialogs", id: "id", fields: [{ name: "draft", purpose: "dialogs.draft" }] },
  { name: "reactions", id: "id", fields: [{ name: "emoji", purpose: "reactions.emoji" }] },
  { name: "inline_protocol_uploads", id: "upload_id", binaryId: true,
    fields: [{ name: "file_name", purpose: "uploads.fileName" }] },
  { name: "inline_uploads", id: "id", fields: [
    { name: "file_name", purpose: "uploads.fileName" }, { name: "waveform", purpose: "voice.waveform", binary: true },
  ] },
  { name: "voices", id: "id", fields: [{ name: "waveform", purpose: "voice.waveform", binary: true }] },
  { name: "url_preview", id: "id", fields: [{ name: "site_name", purpose: "preview.siteName" }] },
  { name: "url_preview_cache", id: "id", fields: [{ name: "site_name", purpose: "preview.siteName" }] },
  { name: "block_content_image_jobs", id: "id", fields: [] },
  { name: "external_tasks", id: "id", fields: [{ name: "url", purpose: "externalTasks.url" }] },
]

const stringValue = (value: unknown): string => {
  if (typeof value !== "string") throw new Error("Unexpected content storage type")
  return value
}
const bytesValue = (value: unknown): Buffer => {
  if (!Buffer.isBuffer(value)) throw new Error("Unexpected binary storage type")
  return value
}
const integerValue = (value: unknown): number => {
  const number = Number(value)
  if (!Number.isSafeInteger(number)) throw new Error("Unexpected identifier type")
  return number
}

export async function backfillContentBatch(options: {
  table: Table; apply: boolean; afterId?: string; batchSize?: number
}) {
  const { table } = options
  if (!contentTables.includes(table)) throw new Error("Unknown content table")
  const size = options.batchSize ?? 100
  if (!Number.isSafeInteger(size) || size < 1 || size > 500) throw new Error("Invalid batch size")
  const tableName = sql.identifier(table.name)
  const id = sql.identifier(table.id)
  const cursor = options.afterId === undefined ? undefined : table.binaryId
    ? Buffer.from(options.afterId, "hex") : BigInt(options.afterId)
  return db.transaction(async (tx) => {
    const rows = await tx.execute<Record<string, unknown>>(sql`
      select * from ${tableName} ${cursor === undefined ? sql`` : sql`where ${id} > ${cursor}`}
      order by ${id} limit ${size} ${options.apply ? sql`for update` : sql`for share`}
    `)
    let changed = 0
    for (const row of rows) {
      const values: Record<string, string | Buffer | number> = {}
      const plaintext = new Map<string, string | Buffer>()
      for (const field of table.fields) {
        if (row[field.name] === null) continue
        if (field.binary) {
          const raw = bytesValue(row[field.name])
          const decoded = openContent(raw, field.purpose)
          plaintext.set(field.name, decoded)
          if (!isSealedContent(raw)) values[field.name] = sealContent(decoded, field.purpose)
        } else {
          const raw = stringValue(row[field.name])
          const decoded = openContentText(raw, field.purpose)
          plaintext.set(field.name, decoded)
          if (!raw.startsWith(CONTENT_PREFIX)) values[field.name] = sealContentText(decoded, field.purpose)
        }
      }
      if (table.name === "chats" && plaintext.has("title")) {
        const hash = chatTitleHash(stringValue(plaintext.get("title")), {
          spaceId: row["space_id"] === null ? null : integerValue(row["space_id"]),
          createdBy: row["created_by"] === null ? null : integerValue(row["created_by"]),
        })
        if (!Buffer.isBuffer(row["title_hash"]) || !hash.equals(row["title_hash"])) values["title_hash"] = hash
      }
      if (table.name === "reactions") {
        const hash = reactionEmojiHash({
          chatId: integerValue(row["chat_id"]), messageId: integerValue(row["message_id"]),
          userId: integerValue(row["user_id"]), emoji: stringValue(plaintext.get("emoji")),
        })
        if (!Buffer.isBuffer(row["emoji_hash"]) || !hash.equals(row["emoji_hash"])) values["emoji_hash"] = hash
      }
      const lookupFields = table.name === "url_preview_cache"
        ? ["url", "image_url", "author_image_url"]
        : table.name === "block_content_image_jobs" ? ["source"] : []
      for (const prefix of lookupFields) {
        const encryptedColumn = prefix === "source" ? "source_encrypted" : prefix
        if (row[encryptedColumn] === null) {
          if (row[`${prefix}_hash`] !== null) throw new Error("Orphaned content fingerprint")
          continue
        }
        const plaintext = decrypt({ encrypted: bytesValue(row[encryptedColumn]),
          iv: bytesValue(row[`${prefix}_iv`]), authTag: bytesValue(row[`${prefix}_tag`]) })
        const hash = contentLookup(prefix === "source" ? "block-image-url" : "preview-url", [], plaintext)
        if (!hash.equals(bytesValue(row[`${prefix}_hash`]))) values[`${prefix}_hash`] = hash
      }
      if (lookupFields.length > 0 && row["hash_version"] !== 1) values["hash_version"] = 1
      if (Object.keys(values).length === 0) continue
      changed++
      if (!options.apply) continue
      const assignments = Object.entries(values).map(([name, value]) => sql`${sql.identifier(name)} = ${value}`)
      const [stored] = await tx.execute<Record<string, unknown>>(sql`
        update ${tableName} set ${sql.join(assignments, sql`, `)} where ${id} = ${row[table.id]} returning *
      `)
      if (!stored) throw new Error("Content row lost during migration")
      for (const [name, expected] of Object.entries(values)) {
        if (Buffer.isBuffer(expected) ? !expected.equals(bytesValue(stored[name])) : stored[name] !== expected) {
          throw new Error("Persisted field verification failed")
        }
      }
      // Verify the persisted representation under the row lock; any mismatch rolls back this batch.
      for (const field of table.fields) {
        const expected = plaintext.get(field.name)
        if (expected === undefined) continue
        const actual = field.binary ? openContent(bytesValue(stored[field.name]), field.purpose)
          : openContentText(stringValue(stored[field.name]), field.purpose)
        if (Buffer.isBuffer(expected) ? !expected.equals(bytesValue(actual)) : expected !== actual) {
          throw new Error("Persisted content verification failed")
        }
      }
    }
    const last = rows.at(-1)?.[table.id]
    return {
      scanned: rows.length, changed, done: rows.length < size,
      lastId: last === undefined ? options.afterId : Buffer.isBuffer(last) ? last.toString("hex") : String(last),
    }
  })
}

// CHECK expressions cannot contain bind parameters. These literals are internal constants.
const prefixLength = sql.raw(String(CONTENT_PREFIX.length))
const prefixText = sql.raw("'inline-content:v1:'")
const prefixBytes = sql.raw("decode('" + Buffer.from(CONTENT_PREFIX).toString("hex") + "', 'hex')")
const encryptedCheck = (field: Field) => field.binary
  ? sql`substring(${sql.identifier(field.name)} from 1 for ${prefixLength}) = ${prefixBytes}`
  : sql`left(${sql.identifier(field.name)}, ${prefixLength}) = ${prefixText}`

/** Count only: no row data, keys, or ciphertext leave the process. */
export async function remainingPlaintext(): Promise<Record<string, number>> {
  const result: Record<string, number> = {}
  for (const table of contentTables) {
    const conditions = table.fields.map((field) =>
      sql`(${sql.identifier(field.name)} is not null and not (${encryptedCheck(field)}))`)
    if (table.name === "chats") conditions.push(sql`title is not null and title_hash is null`)
    if (table.name === "reactions") conditions.push(sql`emoji_hash is null`)
    if (table.name === "url_preview_cache" || table.name === "block_content_image_jobs") conditions.push(sql`hash_version <> 1`)
    const [row] = await db.execute<{ count: number }>(sql`
      select count(*)::integer as count from ${sql.identifier(table.name)} where ${sql.join(conditions, sql` or `)}
    `)
    result[table.name] = row?.count ?? 0
  }
  const [messages] = await db.execute<{ count: number }>(sql`select count(*)::integer as count from messages where text is not null`)
  result["messages"] = messages?.count ?? 0
  const [replay] = await db.execute<{ count: number }>(sql`
    select count(*)::integer as count from inline_protocol_requests where result_body is not null and result_format = 0
  `)
  result["replay"] = replay?.count ?? 0
  return result
}

/** Run only after the global zero-remaining check and confirmation that old writers are gone. */
export async function constrainEncryptedContent(): Promise<void> {
  await db.transaction(async (tx) => {
    await tx.execute(sql`set local lock_timeout = '2s'`)
    for (const table of contentTables) {
      const name = `${table.name}_content_encrypted_v1`
      const [existing] = await tx.execute<{ exists: boolean }>(sql`
        select exists(select 1 from pg_constraint where conname = ${name}
          and conrelid = ${table.name}::regclass) as exists
      `)
      if (existing?.exists) continue
      const conditions = table.fields.map((field) =>
        sql`(${sql.identifier(field.name)} is null or ${encryptedCheck(field)})`)
      if (table.name === "chats") conditions.push(sql`title is null or title_hash is not null`)
      if (table.name === "reactions") conditions.push(sql`emoji_hash is not null`)
      if (table.name === "url_preview_cache" || table.name === "block_content_image_jobs") conditions.push(sql`hash_version = 1`)
      await tx.execute(sql`alter table ${sql.identifier(table.name)} add constraint ${sql.identifier(name)}
        check (${sql.join(conditions.map((condition) => sql`(${condition})`), sql` and `)}) not valid`)
    }
    const [existing] = await tx.execute<{ exists: boolean }>(sql`
      select exists(select 1 from pg_constraint where conname = 'messages_no_plaintext_v1' and conrelid = 'messages'::regclass) as exists
    `)
    if (!existing?.exists) await tx.execute(sql`alter table messages add constraint messages_no_plaintext_v1 check (text is null) not valid`)
    const [replay] = await tx.execute<{ exists: boolean }>(sql`
      select exists(select 1 from pg_constraint where conname = 'replay_no_plaintext_v1'
        and conrelid = 'inline_protocol_requests'::regclass) as exists
    `)
    if (!replay?.exists) await tx.execute(sql`alter table inline_protocol_requests add constraint replay_no_plaintext_v1
      check (result_body is null or result_format = 1) not valid`)
  })
  // Validate separately so the scan does not retain all tables' DDL locks in one transaction.
  for (const table of contentTables) {
    await db.execute(sql`alter table ${sql.identifier(table.name)} validate constraint ${sql.identifier(`${table.name}_content_encrypted_v1`)}`)
  }
  await db.execute(sql`alter table messages validate constraint messages_no_plaintext_v1`)
  await db.execute(sql`alter table inline_protocol_requests validate constraint replay_no_plaintext_v1`)
}
