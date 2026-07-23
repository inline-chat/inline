import type {
  AuthSession,
  AuthSessionPersistence,
  AuthSessionPersistenceLoadResult,
} from "@inline/client/auth"

type DesktopAuthBridge = InlineDesktopApi["auth"]

/** Renderer adapter only. Encryption and filesystem ownership stay in main. */
export class InlineDesktopAuthSessionPersistence
  implements AuthSessionPersistence
{
  constructor(private readonly bridge: DesktopAuthBridge) {}

  async load(): Promise<AuthSessionPersistenceLoadResult> {
    const result = await this.bridge.loadSession()
    if (result.storage === "unavailable") {
      return { status: "unavailable" }
    }
    return { status: "ready", session: result.session }
  }

  async save(session: AuthSession) {
    if (!(await this.bridge.saveSession(session))) {
      throw new Error("Inline desktop credential storage is unavailable")
    }
  }

  async clear() {
    await this.bridge.clearSession()
  }
}
