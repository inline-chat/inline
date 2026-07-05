export type McpGrant = {
  id: string
  clientId: string
  inlineUserId: bigint
  scope: string
  spaceIds: bigint[]
  allowDms: boolean
  allowHomeThreads: boolean
}
