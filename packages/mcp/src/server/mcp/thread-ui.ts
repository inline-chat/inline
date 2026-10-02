import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js"
import { THREAD_RESOURCE_URI, THREAD_RESOURCE_MIME_TYPE, THREAD_RESOURCE_HTML } from "@inline-chat/chatgpt-ui"

export { THREAD_RESOURCE_URI }

// Exact public asset origins are configured independently of browser credentials.
// The production photo proxy is on the API origin; other signed media may use R2.
export function threadResourceDomains(value = process.env.MCP_UI_RESOURCE_DOMAINS ?? ""): string[] {
  const domains = new Set(["https://api.inline.chat"])
  for (const item of value.split(",")) {
    if (!item.trim()) continue
    let url: URL
    try { url = new URL(item.trim()) } catch { throw new Error("Invalid MCP_UI_RESOURCE_DOMAINS origin") }
    if (url.protocol !== "https:" || url.username || url.password || url.pathname !== "/" || url.search || url.hash || url.hostname.includes("*")) {
      throw new Error("MCP_UI_RESOURCE_DOMAINS requires exact HTTPS origins")
    }
    domains.add(url.origin)
  }
  return [...domains]
}

export function registerThreadUi(server: McpServer): void {
  server.registerResource("inline-thread", THREAD_RESOURCE_URI, {
    title: "Inline thread",
    description: "Minimal Inline thread history, replies and text composer.",
    mimeType: THREAD_RESOURCE_MIME_TYPE,
  }, async () => ({ contents: [{
    uri: THREAD_RESOURCE_URI,
    mimeType: THREAD_RESOURCE_MIME_TYPE,
    text: THREAD_RESOURCE_HTML,
    _meta: { ui: {
      prefersBorder: false,
      domain: "https://mcp.inline.chat",
      csp: {
        connectDomains: [],
        resourceDomains: threadResourceDomains(),
        frameDomains: [],
      },
    } },
  }] }))
}
