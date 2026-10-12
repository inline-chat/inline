export type ReplayScope = "user" | "space" | "chat"
const clientTypes = ["ios", "macos", "web", "api", "android", "windows", "linux", "cli", "unknown"] as const
type ClientType = typeof clientTypes[number]
type Progress = "first" | "advance" | "repeat" | "rewind"
export type ReplayProgressOperation = `replay.${ReplayScope}.${ClientType}.${Progress}`

/** Connection/bucket coordinates stay only in bounded process memory. Only fixed
 * cohort names and aggregate counts leave this class. Retries are observations,
 * not errors: empty polls and overlapping clients may legitimately repeat. */
export class ReplayProgress {
  private readonly cursors = new Map<string, { startSeq: number; at: number }>()

  constructor(
    private readonly emit: (operation: ReplayProgressOperation, workItems: number) => void,
    private readonly now: () => number = Date.now,
    private readonly capacity = 4096,
    private readonly ttlMs = 600_000,
  ) {}

  start(identity: string, scope: ReplayScope, client: string | undefined, startSeq: number) {
    const at = this.now()
    const previous = this.cursors.get(identity)
    const progress: Progress = !previous || at - previous.at >= this.ttlMs ? "first"
      : startSeq > previous.startSeq ? "advance" : startSeq === previous.startSeq ? "repeat" : "rewind"
    this.cursors.delete(identity)
    this.cursors.set(identity, { startSeq, at })
    if (this.cursors.size > this.capacity) this.cursors.delete(this.cursors.keys().next().value!)
    const clientType = clientTypes.find((value) => value === client) ?? "unknown"
    // Capture request order before awaiting I/O; completion order can differ.
    return (workItems: number) => this.emit(`replay.${scope}.${clientType}.${progress}`, workItems)
  }
}
