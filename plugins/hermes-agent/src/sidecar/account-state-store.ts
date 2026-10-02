import { readFile, rename, writeFile } from "node:fs/promises"
import { randomUUID } from "node:crypto"
import path from "node:path"
import {
  deserializeStateV1,
  serializeStateV1,
  type InlineSdkState,
  type InlineSdkStateStore,
} from "@inline-chat/realtime-sdk"

/** Keep the SDK format intact while fencing a configured file to its account.
 * The token's public user-id prefix is stable across credential rotation.
 */
export class AccountStateStore implements InlineSdkStateStore {
  private botUserId: string | null
  private readonly origin: string

  constructor(private readonly filePath: string, token: string, baseUrl: string) {
    const fileName = path.basename(filePath).toLowerCase()
    if (fileName === ".env" || fileName.startsWith(".env.") || fileName.endsWith(".env")) {
      throw new Error("Inline state cannot use an environment file")
    }
    this.botUserId = /^([1-9]\d*):/.exec(token)?.[1] ?? null
    const endpoint = new URL(baseUrl)
    this.origin = endpoint.origin + endpoint.pathname.replace(/\/$/, "")
  }

  bindAccount(botUserId: string): void {
    if (this.botUserId && this.botUserId !== botUserId) {
      throw new Error("Inline authenticated account differs from the configured account")
    }
    this.botUserId = botUserId
  }

  async load(): Promise<InlineSdkState | null> {
    let raw: string
    try {
      raw = await readFile(this.filePath, "utf8")
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return null
      throw error
    }
    const parsed = JSON.parse(raw) as { inlineAccount?: { botUserId?: unknown; origin?: unknown } }
    if (parsed.inlineAccount && (
      parsed.inlineAccount.botUserId !== this.botUserId || parsed.inlineAccount.origin !== this.origin
    )) {
      throw new Error("Inline state file belongs to another account or API origin; configure a separate state_path")
    }
    // Legacy files retain their checkpoints. Their original account provenance
    // cannot be reconstructed, so operators must keep the configured profile.
    return deserializeStateV1(raw)
  }

  async save(next: InlineSdkState): Promise<void> {
    if (!this.botUserId) throw new Error("Inline account is not resolved; refusing an unowned checkpoint")
    const payload = JSON.parse(serializeStateV1(next)) as Record<string, unknown>
    payload.inlineAccount = { botUserId: this.botUserId, origin: this.origin }
    const temporaryPath = `${this.filePath}.tmp-${randomUUID()}`
    await writeFile(temporaryPath, JSON.stringify(payload, null, 2), { mode: 0o600 })
    await rename(temporaryPath, this.filePath)
  }
}
