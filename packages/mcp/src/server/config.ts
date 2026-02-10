export type McpConfig = {
  issuer: string
  inlineApiBaseUrl: string
  dbPath: string
  tokenEncryptionKeyB64: string | null
  // Used for generating a stable cookie name to avoid collisions across envs.
  cookiePrefix: string
}

export function defaultConfig(): McpConfig {
  return {
    issuer: process.env.MCP_ISSUER || "http://localhost:8791",
    inlineApiBaseUrl: process.env.INLINE_API_BASE_URL || "https://api.inline.chat",
    dbPath: process.env.MCP_DB_PATH || "./data/inline-mcp.sqlite",
    tokenEncryptionKeyB64: process.env.MCP_TOKEN_ENCRYPTION_KEY_B64 || null,
    cookiePrefix: process.env.MCP_COOKIE_PREFIX || "inline_mcp",
  }
}

