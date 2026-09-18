import { encryptedText, encryptedBytes } from "./encrypted"
import { sql } from "drizzle-orm"
import {
  bigint,
  boolean,
  check,
  index,
  integer,
  jsonb,
  pgTable,
  primaryKey,
  smallint,
  text,
  timestamp,
  uniqueIndex,
  varchar,
} from "drizzle-orm/pg-core"
import { bytea } from "./common"
import { sessions } from "./sessions"
import { users } from "./users"

const protocolTimestamp = (name: string) =>
  timestamp(name, { mode: "date", precision: 3, withTimezone: true })

export const inlineProtocolAuthKeys = pgTable(
  "inline_protocol_auth_keys",
  {
    authKeyId: bytea("auth_key_id").primaryKey(),
    authKeyEncrypted: bytea("auth_key_encrypted").notNull(),
    keyEncryptionKeyId: varchar("key_encryption_key_id", { length: 32 }).notNull(),
    currentServerSalt: bigint("current_server_salt", { mode: "bigint" }).notNull(),
    previousServerSalt: bigint("previous_server_salt", { mode: "bigint" }),
    serverSaltUpdatedAt: protocolTimestamp("server_salt_updated_at").defaultNow().notNull(),
    userId: integer("user_id").references(() => users.id, { onDelete: "set null" }),
    accountSessionId: integer("account_session_id").references(() => sessions.id, { onDelete: "set null" }),
    createdAt: protocolTimestamp("created_at").defaultNow().notNull(),
    authorizedAt: protocolTimestamp("authorized_at"),
    lastUsedAt: protocolTimestamp("last_used_at"),
    expiresAt: protocolTimestamp("expires_at"),
    revokedAt: protocolTimestamp("revoked_at"),
  },
  (table) => ({
    authKeyIdLength: check("inline_protocol_auth_keys_id_length", sql`octet_length(${table.authKeyId}) = 8`),
    encryptedLength: check(
      "inline_protocol_auth_keys_encrypted_length",
      sql`octet_length(${table.authKeyEncrypted}) = 284`,
    ),
    userIndex: index("inline_protocol_auth_keys_user_idx").on(table.userId),
    sessionIndex: index("inline_protocol_auth_keys_session_idx").on(table.accountSessionId),
    expiryIndex: index("inline_protocol_auth_keys_expiry_idx").on(table.expiresAt),
  }),
)

export const inlineProtocolRequests = pgTable(
  "inline_protocol_requests",
  {
    authKeyId: bytea("auth_key_id")
      .notNull(),
    protocolSessionId: bigint("protocol_session_id", { mode: "bigint" }).notNull(),
    messageId: bigint("message_id", { mode: "bigint" }).notNull(),
    requestDigest: bytea("request_digest").notNull(),
    resultBody: bytea("result_body"),
    resultFormat: smallint("result_format").notNull().default(0),
    claimedAt: protocolTimestamp("claimed_at").defaultNow().notNull(),
    completedAt: protocolTimestamp("completed_at"),
    expiresAt: protocolTimestamp("expires_at").notNull(),
  },
  (table) => ({
    identity: primaryKey({
      name: "inline_protocol_requests_pk",
      columns: [table.authKeyId, table.protocolSessionId, table.messageId],
    }),
    authKeyIdLength: check("inline_protocol_requests_key_id_length", sql`octet_length(${table.authKeyId}) = 8`),
    digestLength: check("inline_protocol_requests_digest_length", sql`octet_length(${table.requestDigest}) = 32`),
    resultLength: check(
      "inline_protocol_requests_result_length",
      sql`${table.resultBody} is null or octet_length(${table.resultBody}) <= 16777278`,
    ),
    resultFormatCheck: check(
      "inline_protocol_requests_result_format",
      sql`(${table.resultFormat} = 0 and (${table.resultBody} is null or octet_length(${table.resultBody}) <= 16777216)) or (${table.resultFormat} = 1 and ${table.resultBody} is not null and octet_length(${table.resultBody}) >= 31)`,
    ),
    expiryIndex: index("inline_protocol_requests_expiry_idx").on(table.expiresAt),
  }),
)

export const inlineProtocolAuthChallenges = pgTable(
  "inline_protocol_auth_challenges",
  {
    challengeId: bytea("challenge_id").primaryKey(),
    authKeyId: bytea("auth_key_id")
      .notNull()
      .references(() => inlineProtocolAuthKeys.authKeyId, { onDelete: "cascade" }),
    identifierEncrypted: bytea("identifier_encrypted").notNull(),
    identifierHash: bytea("identifier_hash").notNull(),
    codeMac: bytea("code_mac").notNull(),
    pepperKeyId: varchar("pepper_key_id", { length: 32 }).notNull(),
    delivery: varchar("delivery", { length: 16 }).notNull(),
    client: jsonb("client").$type<Record<string, string>>().notNull(),
    networkHash: bytea("network_hash"),
    deviceHash: bytea("device_hash"),
    attempts: smallint("attempts").default(0).notNull(),
    createdAt: protocolTimestamp("created_at").defaultNow().notNull(),
    expiresAt: protocolTimestamp("expires_at").notNull(),
    consumedAt: protocolTimestamp("consumed_at"),
  },
  (table) => ({
    challengeIdLength: check(
      "inline_protocol_auth_challenges_id_length",
      sql`octet_length(${table.challengeId}) = 32`,
    ),
    authKeyIdLength: check(
      "inline_protocol_auth_challenges_key_id_length",
      sql`octet_length(${table.authKeyId}) = 8`,
    ),
    identifierHashLength: check(
      "inline_protocol_auth_challenges_identifier_hash_length",
      sql`octet_length(${table.identifierHash}) = 32`,
    ),
    codeMacLength: check(
      "inline_protocol_auth_challenges_code_mac_length",
      sql`octet_length(${table.codeMac}) = 32`,
    ),
    authKeyCreatedIndex: index("inline_protocol_auth_challenges_key_created_idx").on(
      table.authKeyId,
      table.createdAt,
    ),
    identifierCreatedIndex: index("inline_protocol_auth_challenges_identifier_created_idx").on(
      table.identifierHash,
      table.createdAt,
    ),
    expiryIndex: index("inline_protocol_auth_challenges_expiry_idx").on(table.expiresAt),
  }),
)

export const inlineProtocolUploads = pgTable(
  "inline_protocol_uploads",
  {
    uploadId: bytea("upload_id").primaryKey(),
    capabilityHash: bytea("capability_hash").notNull(),
    permanentAuthKeyId: bytea("permanent_auth_key_id")
      .notNull()
      .references(() => inlineProtocolAuthKeys.authKeyId, { onDelete: "cascade" }),
    issuingTemporaryAuthKeyId: bytea("issuing_temporary_auth_key_id").notNull(),
    userId: integer("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    accountSessionId: integer("account_session_id")
      .notNull()
      .references(() => sessions.id, { onDelete: "cascade" }),
    fileName: encryptedText("file_name", "uploads.fileName").notNull(),
    mimeType: varchar("mime_type", { length: 255 }).notNull(),
    byteCount: bigint("byte_count", { mode: "bigint" }).notNull(),
    sha256: bytea("sha256").notNull(),
    kind: varchar("kind", { length: 16 }).notNull(),
    status: varchar("status", { length: 16 }).default("pending").notNull(),
    lockToken: bytea("lock_token"),
    lockedAt: protocolTimestamp("locked_at"),
    fileUniqueId: varchar("file_unique_id", { length: 128 }),
    createdAt: protocolTimestamp("created_at").defaultNow().notNull(),
    expiresAt: protocolTimestamp("expires_at").notNull(),
    completedAt: protocolTimestamp("completed_at"),
  },
  (table) => ({
    uploadIdLength: check("inline_protocol_uploads_id_length", sql`octet_length(${table.uploadId}) = 16`),
    capabilityLength: check(
      "inline_protocol_uploads_capability_hash_length",
      sql`octet_length(${table.capabilityHash}) = 32`,
    ),
    permanentKeyLength: check(
      "inline_protocol_uploads_permanent_key_length",
      sql`octet_length(${table.permanentAuthKeyId}) = 8`,
    ),
    temporaryKeyLength: check(
      "inline_protocol_uploads_temporary_key_length",
      sql`octet_length(${table.issuingTemporaryAuthKeyId}) = 8`,
    ),
    shaLength: check("inline_protocol_uploads_sha_length", sql`octet_length(${table.sha256}) = 32`),
    byteCountPositive: check("inline_protocol_uploads_byte_count_positive", sql`${table.byteCount} > 0`),
    statusValid: check(
      "inline_protocol_uploads_status_valid",
      sql`${table.status} in ('pending', 'uploading', 'complete', 'failed')`,
    ),
    capabilityUnique: uniqueIndex("inline_protocol_uploads_capability_unique").on(table.capabilityHash),
    sessionIndex: index("inline_protocol_uploads_session_idx").on(table.accountSessionId, table.createdAt),
    expiryIndex: index("inline_protocol_uploads_expiry_idx").on(table.expiresAt),
  }),
)

export const inlineUploads = pgTable(
  "inline_uploads",
  {
    id: bigint("id", { mode: "number" }).generatedAlwaysAsIdentity().primaryKey(),
    uploadId: bytea("upload_id").notNull(),
    clientUploadId: bytea("client_upload_id").notNull(),
    permanentAuthKeyId: bytea("permanent_auth_key_id")
      .references(() => inlineProtocolAuthKeys.authKeyId, { onDelete: "cascade" }),
    userId: integer("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    accountSessionId: integer("account_session_id")
      .notNull()
      .references(() => sessions.id, { onDelete: "cascade" }),
    fileName: encryptedText("file_name", "uploads.fileName").notNull(),
    mimeType: varchar("mime_type", { length: 255 }).notNull(),
    byteCount: bigint("byte_count", { mode: "bigint" }).notNull(),
    sha256: bytea("sha256").notNull(),
    kind: varchar("kind", { length: 16 }).notNull(),
    thumbnailFileUniqueId: varchar("thumbnail_file_unique_id", { length: 128 }),
    videoWidth: integer("video_width"),
    videoHeight: integer("video_height"),
    duration: integer("duration"),
    isAnimated: boolean("is_animated"),
    hasAudio: boolean("has_audio"),
    waveform: encryptedBytes("waveform", "voice.waveform"),
    partSize: integer("part_size").notNull(),
    partCount: integer("part_count").notNull(),
    status: varchar("status", { length: 16 }).default("uploading").notNull(),
    failureCode: varchar("failure_code", { length: 32 }),
    failureRetryable: boolean("failure_retryable"),
    lockToken: bytea("lock_token"),
    lockedAt: protocolTimestamp("locked_at"),
    storageFormat: varchar("storage_format", { length: 32 }),
    storageUploadId: text("storage_upload_id"),
    retryAt: protocolTimestamp("retry_at"),
    attempts: integer("attempts").default(0).notNull(),
    resultFileUniqueId: varchar("result_file_unique_id", { length: 128 }),
    resultMediaId: bigint("result_media_id", { mode: "number" }),
    createdAt: protocolTimestamp("created_at").defaultNow().notNull(),
    lastPartAt: protocolTimestamp("last_part_at"),
    expiresAt: protocolTimestamp("expires_at").notNull(),
    hardExpiresAt: protocolTimestamp("hard_expires_at").notNull(),
    completedAt: protocolTimestamp("completed_at"),
    canceledAt: protocolTimestamp("canceled_at"),
  },
  (table) => ({
    uploadIdLength: check("inline_uploads_id_length", sql`octet_length(${table.uploadId}) = 16`),
    clientUploadIdLength: check(
      "inline_uploads_client_id_length",
      sql`octet_length(${table.clientUploadId}) = 16`,
    ),
    permanentKeyLength: check(
      "inline_uploads_permanent_key_length",
      sql`octet_length(${table.permanentAuthKeyId}) = 8`,
    ),
    shaLength: check("inline_uploads_sha_length", sql`octet_length(${table.sha256}) = 32`),
    byteCountPositive: check("inline_uploads_byte_count_positive", sql`${table.byteCount} > 0`),
    partSizeValid: check(
      "inline_uploads_part_size_valid",
      sql`${table.partSize} = 524288`,
    ),
    partCountValid: check(
      "inline_uploads_part_count_valid",
      sql`${table.partCount} between 1 and 1000`,
    ),
    kindValid: check(
      "inline_uploads_kind_valid",
      sql`${table.kind} in ('photo', 'video', 'document', 'voice')`,
    ),
    statusValid: check(
      "inline_uploads_status_valid",
      sql`${table.status} in ('uploading', 'processing', 'complete', 'failed', 'canceled')`,
    ),
    storageFormatValid: check(
      "inline_uploads_storage_format_valid",
      sql`${table.storageFormat} is null or ${table.storageFormat} = 'identity_v1'`,
    ),
    storageSessionValid: check(
      "inline_uploads_storage_session_valid",
      sql`${table.storageUploadId} is null or ${table.storageFormat} is not null`,
    ),
    attemptsValid: check("inline_uploads_attempts_valid", sql`${table.attempts} >= 0`),
    uploadIdUnique: uniqueIndex("inline_uploads_upload_id_unique").on(table.uploadId),
    clientIdUnique: uniqueIndex("inline_uploads_session_client_id_unique").on(
      table.accountSessionId,
      table.clientUploadId,
    ),
    permanentKeyIndex: index("inline_uploads_permanent_key_idx").on(table.permanentAuthKeyId),
    userStatusIndex: index("inline_uploads_user_status_idx").on(table.userId, table.status),
    sessionCreatedIndex: index("inline_uploads_session_created_idx").on(
      table.accountSessionId,
      table.createdAt,
    ),
    expiryIndex: index("inline_uploads_expiry_idx").on(table.status, table.expiresAt),
    processingRetryIndex: index("inline_uploads_processing_retry_idx").on(table.status, table.retryAt),
  }),
)

export const inlineUploadParts = pgTable(
  "inline_upload_parts",
  {
    uploadDbId: bigint("upload_id", { mode: "number" })
      .notNull()
      .references(() => inlineUploads.id, { onDelete: "cascade" }),
    partIndex: integer("part_index").notNull(),
    byteCount: integer("byte_count").notNull(),
    sha256: bytea("sha256").notNull(),
    // Nullable through the mixed-version rollout: an older server can still
    // accept legacy/null-format uploads while new servers dual-write these.
    storedByteCount: integer("stored_byte_count"),
    storedSha256: bytea("stored_sha256"),
    objectKey: text("object_key").notNull(),
    acceptedAt: protocolTimestamp("accepted_at").defaultNow().notNull(),
  },
  (table) => ({
    identity: primaryKey({
      name: "inline_upload_parts_pk",
      columns: [table.uploadDbId, table.partIndex],
    }),
    partIndexValid: check("inline_upload_parts_index_valid", sql`${table.partIndex} >= 0`),
    byteCountValid: check(
      "inline_upload_parts_byte_count_valid",
      sql`${table.byteCount} between 1 and 524288`,
    ),
    shaLength: check("inline_upload_parts_sha_length", sql`octet_length(${table.sha256}) = 32`),
    storedByteCountValid: check(
      "inline_upload_parts_stored_byte_count_valid",
      sql`${table.storedByteCount} > 0`,
    ),
    storedShaLength: check(
      "inline_upload_parts_stored_sha_length",
      sql`octet_length(${table.storedSha256}) = 32`,
    ),
  }),
)

export const inlineUploadStorageParts = pgTable(
  "inline_upload_storage_parts",
  {
    uploadDbId: bigint("upload_id", { mode: "number" })
      .notNull()
      .references(() => inlineUploads.id, { onDelete: "cascade" }),
    storageUploadId: text("storage_upload_id").notNull(),
    partNumber: integer("part_number").notNull(),
    storedByteCount: integer("stored_byte_count").notNull(),
    storedSha256: bytea("stored_sha256").notNull(),
    etag: text("etag").notNull(),
    completedAt: protocolTimestamp("completed_at").defaultNow().notNull(),
  },
  (table) => ({
    identity: primaryKey({
      name: "inline_upload_storage_parts_pk",
      columns: [table.uploadDbId, table.partNumber],
    }),
    partNumberValid: check(
      "inline_upload_storage_parts_number_valid",
      sql`${table.partNumber} between 1 and 1000`,
    ),
    storedByteCountValid: check(
      "inline_upload_storage_parts_byte_count_valid",
      sql`${table.storedByteCount} > 0`,
    ),
    storedShaLength: check(
      "inline_upload_storage_parts_sha_length",
      sql`octet_length(${table.storedSha256}) = 32`,
    ),
    etagValid: check(
      "inline_upload_storage_parts_etag_valid",
      sql`length(${table.etag}) between 1 and 128`,
    ),
  }),
)

export type DbInlineProtocolAuthKey = typeof inlineProtocolAuthKeys.$inferSelect
export type DbNewInlineProtocolAuthKey = typeof inlineProtocolAuthKeys.$inferInsert
export type DbInlineProtocolRequest = typeof inlineProtocolRequests.$inferSelect
export type DbInlineProtocolAuthChallenge = typeof inlineProtocolAuthChallenges.$inferSelect
export type DbInlineProtocolUpload = typeof inlineProtocolUploads.$inferSelect
export type DbInlineUpload = typeof inlineUploads.$inferSelect
export type DbInlineUploadPart = typeof inlineUploadParts.$inferSelect
export type DbInlineUploadStoragePart = typeof inlineUploadStorageParts.$inferSelect
