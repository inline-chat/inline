import type { PreviewCredential } from "@inline-chat/url-preview"

export type PreviewAuthProvider = "notion" | (string & {})

export type PreviewAuthInput = {
  provider: PreviewAuthProvider
  currentUserId: number
  chatId: number
}

export type PreviewAuthPolicy = {
  allowUserTokenFallbackInSpaceChats: boolean
}

export type PreviewIntegrationRow = {
  id: number
  provider: string
  userId: number | null
  spaceId: number | null
  accessTokenEncrypted: Buffer | null
  accessTokenIv: Buffer | null
  accessTokenTag: Buffer | null
}

export type PreviewAuthToken = PreviewCredential & {
  integrationId: number
  owner: NonNullable<PreviewCredential["owner"]>
}

export type PreviewAuthResolverDeps = {
  getChatSpaceId(chatId: number): Promise<number | null>
  findSpaceIntegration(provider: string, spaceId: number): Promise<PreviewIntegrationRow | null>
  findUserIntegration(provider: string, userId: number): Promise<PreviewIntegrationRow | null>
  decryptToken(row: PreviewIntegrationRow): unknown
}
