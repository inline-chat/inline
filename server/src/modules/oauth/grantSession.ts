import { AuthTokenError, getUserIdFromToken } from "@in/server/modules/auth/sessionAuthentication"

// OAuth access cannot outlive the Inline authority backing its grant. Treat
// authentication rejection as inactive, while infrastructure failures remain
// retryable server failures rather than a false revocation decision.
export async function isGrantSessionActive(token: string, userId: number): Promise<boolean> {
  try {
    const session = await getUserIdFromToken(token)
    return session.userId === userId
  } catch (error) {
    if (error instanceof AuthTokenError) return false
    throw error
  }
}
