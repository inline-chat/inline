export type McpGrant = {
  id: string
  clientId: string
  inlineUserId: bigint
  scope: string
  spaceIds: bigint[]
  allowDms: boolean
  allowHomeThreads: boolean
  /** Known agent id this connection's messages are sent via ("chatgpt"); absent from older servers. */
  viaApp?: string
  /** The user let this app send without "Sent via <name>" when they ask. */
  allowUnsigned?: boolean
}
