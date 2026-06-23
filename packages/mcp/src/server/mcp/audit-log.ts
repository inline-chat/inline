export type MessagesSendAuditOutcome = "success" | "failure"

export type MessagesSendAuditEvent = {
  outcome: MessagesSendAuditOutcome
  grantId: string
  inlineUserId: string
  chatId: string | null
  spaceId: string | null
  messageId: string | null
}

export function logMessagesSendAudit(event: MessagesSendAuditEvent): void {
  const payload = {
    event: "mcp.audit",
    tool: "messages.send",
    timestamp: new Date().toISOString(),
    outcome: event.outcome,
    grantId: event.grantId,
    inlineUserId: event.inlineUserId,
    chatId: event.chatId,
    spaceId: event.spaceId,
    messageId: event.messageId,
  }
  console.info(JSON.stringify(payload))
}
