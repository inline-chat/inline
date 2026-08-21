import type { OAuthResourcePolicy } from "./resource-policy.js"

export const MCP_SUPPORTED_SCOPES = ["offline_access", "messages:read", "messages:write", "spaces:read"] as const
export type McpSupportedScope = (typeof MCP_SUPPORTED_SCOPES)[number]
export const MCP_RESOURCE_SCOPES = ["messages:read", "messages:write", "spaces:read"] as const
export const MCP_DEFAULT_SCOPE = "messages:read spaces:read"

export const MCP_RESOURCE_POLICY: OAuthResourcePolicy<McpSupportedScope> = {
  resource: "https://mcp.inline.chat",
  supportedScopes: MCP_SUPPORTED_SCOPES,
  defaultScopes: ["messages:read", "spaces:read"],
  resourceScopes: MCP_RESOURCE_SCOPES,
}
