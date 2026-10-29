import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto"
import { appendFileSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, statSync, utimesSync, writeFileSync } from "node:fs"
import { isAbsolute, join } from "node:path"
import { TranscriptionError, type Model } from "./protocol.js"

export type SpoolConfig = Readonly<{ dir: string; key: string; maxBytes: number }>
export type SpooledTurn = Readonly<{
  segmentId: string; model: Model; sampleRate: number; admittedAtMs: number;
  closed: boolean; handoff: boolean; touchedAtMs: number;
}>
/** What a speaker pipeline needs; every method is best effort and never throws. */
export interface TurnSpoolWriter {
  open(segmentId: string, model: Model, sampleRate: number): boolean
  append(segmentId: string, samples: Int16Array): boolean
  close(segmentId: string): void
  handoff(segmentId: string): void
  touch(segmentId: string): void
  remove(segmentId: string): void
}

const SEGMENT_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const IV_BYTES = 12
const TAG_BYTES = 16

/** Spooling is opt-in: both a private directory and a 32-byte base64 key are required. */
export function spoolConfig(environment: Readonly<Record<string, string | undefined>>): SpoolConfig | undefined {
  const dir = environment.GRID_TRANSCRIPTION_SPOOL_DIR
  const key = environment.GRID_TRANSCRIPTION_SPOOL_KEY
  if (!dir && !key) return undefined
  const maxMegabytes = Number(environment.GRID_TRANSCRIPTION_SPOOL_MAX_MB ?? "2048")
  if (!dir || !key || !isAbsolute(dir) || Buffer.from(key, "base64").length !== 32
    || !Number.isSafeInteger(maxMegabytes) || maxMegabytes < 1) throw new TranscriptionError("protocol")
  return Object.freeze({ dir, key, maxBytes: maxMegabytes * 1024 * 1024 })
}

/**
 * Admitted speech survives provider outages and worker restarts on disk until its text is
 * persisted. Audio is sealed per frame with AES-256-GCM bound to its segment; metadata holds
 * no content. Files are removed once the API stores the turn, or after the late-final window.
 */
export class TurnSpool implements TurnSpoolWriter {
  private readonly key: Buffer

  constructor(private readonly config: SpoolConfig) {
    this.key = Buffer.from(config.key, "base64")
    mkdirSync(config.dir, { recursive: true, mode: 0o700 })
  }

  open(segmentId: string, model: Model, sampleRate: number): boolean {
    if (!SEGMENT_ID.test(segmentId)) return false
    try {
      if (this.usage() >= this.config.maxBytes) return false
      writeFileSync(this.audioPath(segmentId), Buffer.alloc(0), { mode: 0o600 })
      this.writeMeta({ segmentId, model, sampleRate, admittedAtMs: Date.now(), closed: false, handoff: false, touchedAtMs: Date.now() })
      return true
    } catch { this.remove(segmentId); return false }
  }

  append(segmentId: string, samples: Int16Array): boolean {
    try {
      const iv = randomBytes(IV_BYTES)
      const cipher = createCipheriv("aes-256-gcm", this.key, iv)
      cipher.setAAD(Buffer.from(segmentId))
      const sealed = Buffer.concat([cipher.update(Buffer.from(samples.buffer, samples.byteOffset, samples.byteLength)), cipher.final()])
      const header = Buffer.alloc(4)
      header.writeUInt32LE(sealed.length)
      appendFileSync(this.audioPath(segmentId), Buffer.concat([header, iv, cipher.getAuthTag(), sealed]))
      return true
    } catch { this.remove(segmentId); return false }
  }

  close(segmentId: string): void { this.updateMeta(segmentId, { closed: true }) }
  handoff(segmentId: string): void { this.updateMeta(segmentId, { closed: true, handoff: true }) }

  touch(segmentId: string): void {
    try { const now = new Date(); utimesSync(this.metaPath(segmentId), now, now) } catch { /* Recovery treats it as stale. */ }
  }

  remove(segmentId: string): void {
    if (!SEGMENT_ID.test(segmentId)) return
    rmSync(this.audioPath(segmentId), { force: true })
    rmSync(this.metaPath(segmentId), { force: true })
  }

  list(): SpooledTurn[] {
    const turns: SpooledTurn[] = []
    for (const name of readdirSync(this.config.dir)) {
      if (!name.endsWith(".json")) continue
      try {
        const path = join(this.config.dir, name)
        const meta = JSON.parse(readFileSync(path, "utf8")) as Omit<SpooledTurn, "touchedAtMs">
        if (!SEGMENT_ID.test(meta.segmentId) || `${meta.segmentId}.json` !== name) continue
        turns.push({ ...meta, touchedAtMs: statSync(path).mtimeMs })
      } catch { /* A torn metadata write is retried by its owner or expires. */ }
    }
    return turns.sort((left, right) => left.admittedAtMs - right.admittedAtMs)
  }

  read(segmentId: string): Int16Array {
    const file = readFileSync(this.audioPath(segmentId))
    const chunks: Buffer[] = []
    for (let offset = 0; offset + 4 + IV_BYTES + TAG_BYTES <= file.length;) {
      const length = file.readUInt32LE(offset)
      const start = offset + 4 + IV_BYTES + TAG_BYTES
      // A record torn by a crash ends the readable audio; everything before it is intact.
      if (start + length > file.length) break
      const decipher = createDecipheriv("aes-256-gcm", this.key, file.subarray(offset + 4, offset + 4 + IV_BYTES))
      decipher.setAAD(Buffer.from(segmentId))
      decipher.setAuthTag(file.subarray(offset + 4 + IV_BYTES, start))
      chunks.push(Buffer.concat([decipher.update(file.subarray(start, start + length)), decipher.final()]))
      offset = start + length
    }
    const pcm = Buffer.concat(chunks)
    return new Int16Array(pcm.buffer.slice(pcm.byteOffset, pcm.byteOffset + pcm.byteLength - (pcm.byteLength % 2)))
  }

  private usage(): number {
    let total = 0
    for (const name of readdirSync(this.config.dir)) {
      try { total += statSync(join(this.config.dir, name)).size } catch { /* Removed concurrently. */ }
    }
    return total
  }
  private updateMeta(segmentId: string, change: Partial<SpooledTurn>): void {
    try {
      const meta = JSON.parse(readFileSync(this.metaPath(segmentId), "utf8")) as SpooledTurn
      this.writeMeta({ ...meta, ...change })
    } catch { /* Never spooled, or already removed. */ }
  }
  private writeMeta(meta: SpooledTurn): void {
    const { touchedAtMs: _touched, ...stored } = meta
    const temporary = `${this.metaPath(meta.segmentId)}.tmp`
    writeFileSync(temporary, JSON.stringify(stored), { mode: 0o600 })
    renameSync(temporary, this.metaPath(meta.segmentId))
  }
  private audioPath(segmentId: string): string { return join(this.config.dir, `${segmentId}.pcm`) }
  private metaPath(segmentId: string): string { return join(this.config.dir, `${segmentId}.json`) }
}
