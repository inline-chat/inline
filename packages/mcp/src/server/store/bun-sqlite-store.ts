import { Database } from "bun:sqlite"
import type { McpConfig } from "../config"
import { mkdirSync } from "node:fs"
import { dirname } from "node:path"
import type {
  AuthCode,
  AuthRequest,
  Grant,
  RegisteredClient,
  StoredAccessToken,
  StoredRefreshToken,
  Store,
} from "./types"

export function createBunSqliteStore(config: Pick<McpConfig, "dbPath">): Store {
  if (config.dbPath !== ":memory:") {
    // Ensure the parent directory exists so Bun's sqlite can create the file.
    mkdirSync(dirname(config.dbPath), { recursive: true })
  }
  const db = new Database(config.dbPath)
  const store = new BunSqliteStore(db)
  store.ensureSchema()
  return store
}

class BunSqliteStore implements Store {
  constructor(private readonly db: Database) {}

  ensureSchema(): void {
    this.db.exec(`
      pragma journal_mode = wal;
      create table if not exists oauth_clients (
        client_id text primary key,
        redirect_uris_json text not null,
        client_name text,
        created_at_ms integer not null
      );
      create table if not exists auth_requests (
        id text primary key,
        client_id text not null,
        redirect_uri text not null,
        state text not null,
        scope text not null,
        code_challenge text not null,
        csrf_token text not null,
        device_id text not null,
        inline_user_id text,
        email text,
        inline_token_enc text,
        created_at_ms integer not null,
        expires_at_ms integer not null
      );
      create table if not exists grants (
        id text primary key,
        client_id text not null,
        inline_user_id text not null,
        scope text not null,
        space_ids_json text not null,
        inline_token_enc text not null,
        created_at_ms integer not null,
        revoked_at_ms integer
      );
      create table if not exists auth_codes (
        code text primary key,
        grant_id text not null,
        client_id text not null,
        redirect_uri text not null,
        code_challenge text not null,
        used_at_ms integer,
        created_at_ms integer not null,
        expires_at_ms integer not null
      );
      create table if not exists access_tokens (
        token_hash_hex text primary key,
        grant_id text not null,
        created_at_ms integer not null,
        expires_at_ms integer not null,
        revoked_at_ms integer
      );
      create table if not exists refresh_tokens (
        token_hash_hex text primary key,
        grant_id text not null,
        created_at_ms integer not null,
        expires_at_ms integer not null,
        revoked_at_ms integer,
        replaced_by_hash_hex text
      );
    `)
  }

  cleanupExpired(nowMs: number): void {
    this.db.query("delete from auth_requests where expires_at_ms <= ?").run(nowMs)
    this.db.query("delete from auth_codes where expires_at_ms <= ?").run(nowMs)
  }

  createClient(input: { redirectUris: string[]; clientName: string | null; nowMs: number }): RegisteredClient {
    const clientId = crypto.randomUUID()
    this.db
      .query("insert into oauth_clients (client_id, redirect_uris_json, client_name, created_at_ms) values (?, ?, ?, ?)")
      .run(clientId, JSON.stringify(input.redirectUris), input.clientName, input.nowMs)
    return { clientId, redirectUris: input.redirectUris, clientName: input.clientName, createdAtMs: input.nowMs }
  }

  getClient(clientId: string): RegisteredClient | null {
    const row = this.db
      .query<{ client_id: string; redirect_uris_json: string; client_name: string | null; created_at_ms: number }, [string]>(
        "select client_id, redirect_uris_json, client_name, created_at_ms from oauth_clients where client_id = ?",
      )
      .get(clientId)
    if (!row) return null
    return {
      clientId: row.client_id,
      redirectUris: JSON.parse(row.redirect_uris_json) as string[],
      clientName: row.client_name,
      createdAtMs: row.created_at_ms,
    }
  }

  createAuthRequest(input: {
    id: string
    clientId: string
    redirectUri: string
    state: string
    scope: string
    codeChallenge: string
    csrfToken: string
    deviceId: string
    nowMs: number
    expiresAtMs: number
  }): AuthRequest {
    this.db
      .query(
        "insert into auth_requests (id, client_id, redirect_uri, state, scope, code_challenge, csrf_token, device_id, created_at_ms, expires_at_ms) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
      )
      .run(
        input.id,
        input.clientId,
        input.redirectUri,
        input.state,
        input.scope,
        input.codeChallenge,
        input.csrfToken,
        input.deviceId,
        input.nowMs,
        input.expiresAtMs,
      )
    return {
      id: input.id,
      clientId: input.clientId,
      redirectUri: input.redirectUri,
      state: input.state,
      scope: input.scope,
      codeChallenge: input.codeChallenge,
      csrfToken: input.csrfToken,
      deviceId: input.deviceId,
      inlineUserId: null,
      email: null,
      inlineTokenEnc: null,
      createdAtMs: input.nowMs,
      expiresAtMs: input.expiresAtMs,
    }
  }

  getAuthRequest(id: string, nowMs: number): AuthRequest | null {
    const row = this.db
      .query<
        {
          id: string
          client_id: string
          redirect_uri: string
          state: string
          scope: string
          code_challenge: string
          csrf_token: string
          device_id: string
          inline_user_id: string | null
          email: string | null
          inline_token_enc: string | null
          created_at_ms: number
          expires_at_ms: number
        },
        [string]
      >(
        "select id, client_id, redirect_uri, state, scope, code_challenge, csrf_token, device_id, inline_user_id, email, inline_token_enc, created_at_ms, expires_at_ms from auth_requests where id = ?",
      )
      .get(id)
    if (!row) return null
    if (row.expires_at_ms <= nowMs) return null
    return {
      id: row.id,
      clientId: row.client_id,
      redirectUri: row.redirect_uri,
      state: row.state,
      scope: row.scope,
      codeChallenge: row.code_challenge,
      csrfToken: row.csrf_token,
      deviceId: row.device_id,
      inlineUserId: row.inline_user_id ? BigInt(row.inline_user_id) : null,
      email: row.email,
      inlineTokenEnc: row.inline_token_enc,
      createdAtMs: row.created_at_ms,
      expiresAtMs: row.expires_at_ms,
    }
  }

  setAuthRequestEmail(id: string, email: string): void {
    this.db.query("update auth_requests set email = ? where id = ?").run(email, id)
  }

  setAuthRequestInlineTokenEnc(id: string, inlineTokenEnc: string): void {
    this.db.query("update auth_requests set inline_token_enc = ? where id = ?").run(inlineTokenEnc, id)
  }

  setAuthRequestInlineUserId(id: string, inlineUserId: bigint): void {
    this.db.query("update auth_requests set inline_user_id = ? where id = ?").run(inlineUserId.toString(), id)
  }

  deleteAuthRequest(id: string): void {
    this.db.query("delete from auth_requests where id = ?").run(id)
  }

  createGrant(input: {
    id: string
    clientId: string
    inlineUserId: bigint
    scope: string
    spaceIds: bigint[]
    inlineTokenEnc: string
    nowMs: number
  }): Grant {
    this.db
      .query(
        "insert into grants (id, client_id, inline_user_id, scope, space_ids_json, inline_token_enc, created_at_ms) values (?, ?, ?, ?, ?, ?, ?)",
      )
      .run(
        input.id,
        input.clientId,
        input.inlineUserId.toString(),
        input.scope,
        JSON.stringify(input.spaceIds.map((s) => s.toString())),
        input.inlineTokenEnc,
        input.nowMs,
      )
    return {
      id: input.id,
      clientId: input.clientId,
      inlineUserId: input.inlineUserId,
      scope: input.scope,
      spaceIds: input.spaceIds,
      inlineTokenEnc: input.inlineTokenEnc,
      createdAtMs: input.nowMs,
      revokedAtMs: null,
    }
  }

  getGrant(grantId: string): Grant | null {
    const row = this.db
      .query<
        {
          id: string
          client_id: string
          inline_user_id: string
          scope: string
          space_ids_json: string
          inline_token_enc: string
          created_at_ms: number
          revoked_at_ms: number | null
        },
        [string]
      >(
        "select id, client_id, inline_user_id, scope, space_ids_json, inline_token_enc, created_at_ms, revoked_at_ms from grants where id = ?",
      )
      .get(grantId)
    if (!row) return null
    return {
      id: row.id,
      clientId: row.client_id,
      inlineUserId: BigInt(row.inline_user_id),
      scope: row.scope,
      spaceIds: (JSON.parse(row.space_ids_json) as string[]).map((s) => BigInt(s)),
      inlineTokenEnc: row.inline_token_enc,
      createdAtMs: row.created_at_ms,
      revokedAtMs: row.revoked_at_ms,
    }
  }

  createAuthCode(input: {
    code: string
    grantId: string
    clientId: string
    redirectUri: string
    codeChallenge: string
    nowMs: number
    expiresAtMs: number
  }): AuthCode {
    this.db
      .query(
        "insert into auth_codes (code, grant_id, client_id, redirect_uri, code_challenge, created_at_ms, expires_at_ms) values (?, ?, ?, ?, ?, ?, ?)",
      )
      .run(input.code, input.grantId, input.clientId, input.redirectUri, input.codeChallenge, input.nowMs, input.expiresAtMs)
    return {
      code: input.code,
      grantId: input.grantId,
      clientId: input.clientId,
      redirectUri: input.redirectUri,
      codeChallenge: input.codeChallenge,
      usedAtMs: null,
      createdAtMs: input.nowMs,
      expiresAtMs: input.expiresAtMs,
    }
  }

  getAuthCode(code: string, nowMs: number): AuthCode | null {
    const row = this.db
      .query<
        {
          code: string
          grant_id: string
          client_id: string
          redirect_uri: string
          code_challenge: string
          used_at_ms: number | null
          created_at_ms: number
          expires_at_ms: number
        },
        [string]
      >(
        "select code, grant_id, client_id, redirect_uri, code_challenge, used_at_ms, created_at_ms, expires_at_ms from auth_codes where code = ?",
      )
      .get(code)
    if (!row) return null
    if (row.expires_at_ms <= nowMs) return null
    return {
      code: row.code,
      grantId: row.grant_id,
      clientId: row.client_id,
      redirectUri: row.redirect_uri,
      codeChallenge: row.code_challenge,
      usedAtMs: row.used_at_ms,
      createdAtMs: row.created_at_ms,
      expiresAtMs: row.expires_at_ms,
    }
  }

  markAuthCodeUsed(code: string, nowMs: number): void {
    this.db.query("update auth_codes set used_at_ms = ? where code = ?").run(nowMs, code)
  }

  createAccessToken(input: { tokenHashHex: string; grantId: string; nowMs: number; expiresAtMs: number }): void {
    this.db
      .query(
        "insert into access_tokens (token_hash_hex, grant_id, created_at_ms, expires_at_ms) values (?, ?, ?, ?)",
      )
      .run(input.tokenHashHex, input.grantId, input.nowMs, input.expiresAtMs)
  }

  getAccessToken(tokenHashHex: string, nowMs: number): StoredAccessToken | null {
    const row = this.db
      .query<
        { token_hash_hex: string; grant_id: string; created_at_ms: number; expires_at_ms: number; revoked_at_ms: number | null },
        [string]
      >("select token_hash_hex, grant_id, created_at_ms, expires_at_ms, revoked_at_ms from access_tokens where token_hash_hex = ?")
      .get(tokenHashHex)
    if (!row) return null
    if (row.revoked_at_ms != null) return null
    if (row.expires_at_ms <= nowMs) return null
    return {
      tokenHashHex: row.token_hash_hex,
      grantId: row.grant_id,
      createdAtMs: row.created_at_ms,
      expiresAtMs: row.expires_at_ms,
      revokedAtMs: row.revoked_at_ms,
    }
  }

  createRefreshToken(input: { tokenHashHex: string; grantId: string; nowMs: number; expiresAtMs: number }): void {
    this.db
      .query(
        "insert into refresh_tokens (token_hash_hex, grant_id, created_at_ms, expires_at_ms) values (?, ?, ?, ?)",
      )
      .run(input.tokenHashHex, input.grantId, input.nowMs, input.expiresAtMs)
  }

  getRefreshToken(tokenHashHex: string, nowMs: number): StoredRefreshToken | null {
    const row = this.db
      .query<
        {
          token_hash_hex: string
          grant_id: string
          created_at_ms: number
          expires_at_ms: number
          revoked_at_ms: number | null
          replaced_by_hash_hex: string | null
        },
        [string]
      >(
        "select token_hash_hex, grant_id, created_at_ms, expires_at_ms, revoked_at_ms, replaced_by_hash_hex from refresh_tokens where token_hash_hex = ?",
      )
      .get(tokenHashHex)
    if (!row) return null
    if (row.revoked_at_ms != null) return null
    if (row.expires_at_ms <= nowMs) return null
    return {
      tokenHashHex: row.token_hash_hex,
      grantId: row.grant_id,
      createdAtMs: row.created_at_ms,
      expiresAtMs: row.expires_at_ms,
      revokedAtMs: row.revoked_at_ms,
      replacedByHashHex: row.replaced_by_hash_hex,
    }
  }

  revokeRefreshToken(tokenHashHex: string, nowMs: number, replacedByHashHex: string | null): void {
    this.db
      .query("update refresh_tokens set revoked_at_ms = ?, replaced_by_hash_hex = ? where token_hash_hex = ?")
      .run(nowMs, replacedByHashHex, tokenHashHex)
  }
}
