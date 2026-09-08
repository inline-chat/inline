/** Display classification only; never an authentication or permission decision. */
export function oauthClientKind(clientName: string | null | undefined): "chatgpt" | "mcp" {
  return clientName?.trim().toLowerCase() === "chatgpt" ? "chatgpt" : "mcp"
}
