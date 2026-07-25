import { app, safeStorage } from "electron"
import { mkdir, readFile, rename, writeFile } from "node:fs/promises"
import path from "node:path"
import type {
  InlineDesktopAuthLoadResult,
  InlineDesktopAuthSession,
} from "../platform/DesktopApi"

const decodeAuthSession = (value: unknown): InlineDesktopAuthSession | undefined => {
  if (!value || typeof value !== "object") return undefined
  const candidate = value as Partial<InlineDesktopAuthSession>
  const userId = parseInlineDesktopUserId(candidate.userId)
  if (typeof candidate.token !== "string" || candidate.token.length === 0 || !userId) {
    return undefined
  }
  return { token: candidate.token, userId }
}

const parseInlineDesktopUserId = (
  value: unknown,
): string | undefined => {
  if (
    typeof value !== "string" ||
    !/^[1-9]\d*$/.test(value)
  ) {
    return undefined
  }
  const exact = BigInt(value)
  return exact <= (1n << 63n) - 1n ? exact.toString() : undefined
}

export class InlineSessionVault {
  private readonly sessionPath = path.join(app.getPath("userData"), "inline-session.bin")

  async load(): Promise<InlineDesktopAuthLoadResult> {
    if (!(await this.encryptionAvailable())) {
      return { session: null, storage: "unavailable" }
    }

    try {
      const encrypted = await readFile(this.sessionPath)
      if (encrypted.byteLength === 0) {
        return { session: null, storage: "encrypted" }
      }

      const decrypted = await safeStorage.decryptStringAsync(encrypted)
      const parsed: unknown = JSON.parse(decrypted.result)
      const session = decodeAuthSession(parsed)
      if (!session) {
        return { session: null, storage: "encrypted" }
      }

      if (decrypted.shouldReEncrypt || (parsed as { userId?: unknown }).userId !== session.userId) {
        await this.save(session)
      }

      return { session, storage: "encrypted" }
    } catch {
      return { session: null, storage: "encrypted" }
    }
  }

  async save(session: InlineDesktopAuthSession): Promise<boolean> {
    const decoded = decodeAuthSession(session)
    if (!decoded || !(await this.encryptionAvailable())) return false

    const encrypted = await safeStorage.encryptStringAsync(JSON.stringify(decoded))
    await mkdir(path.dirname(this.sessionPath), { recursive: true, mode: 0o700 })
    const nextPath = `${this.sessionPath}.next`
    await writeFile(nextPath, encrypted, { mode: 0o600 })
    await rename(nextPath, this.sessionPath)
    return true
  }

  async clear(): Promise<void> {
    await mkdir(path.dirname(this.sessionPath), { recursive: true, mode: 0o700 })
    await writeFile(this.sessionPath, Buffer.alloc(0), { mode: 0o600 })
  }

  private async encryptionAvailable() {
    if (!(await safeStorage.isAsyncEncryptionAvailable())) return false
    return process.platform !== "linux" || safeStorage.getSelectedStorageBackend() !== "basic_text"
  }
}
