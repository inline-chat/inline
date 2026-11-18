/**
 * The diagnostics a user can copy from the failure screen. Redacted by
 * construction (`web/docs/security.md`, "Session and storage"): IDs, states,
 * counters, timings and the app's log ring buffer, whose fields `@inline/log`
 * already sanitizes. Never message text, tokens or keys.
 */

import type { CoreResource } from "@inline/core-protocol"
import type { LogRecord } from "@inline/log"
import type { RecordedMeasure } from "./perf"

export type DiagnosticsInput = {
  readonly buildId: string
  readonly phase: string
  readonly status?: string
  readonly core?: CoreResource | undefined
  readonly role?: string | undefined
  /** App paths of the panes' destinations (IDs only). */
  readonly panes?: readonly string[]
  readonly measures?: readonly RecordedMeasure[]
  readonly logs?: readonly LogRecord[]
  readonly userAgent?: string
  readonly now?: number
}

/** Plain JSON text, newest log records last. */
export const buildDiagnostics = (input: DiagnosticsInput): string => {
  const core = input.core
  const report = {
    kind: "inline-web-diagnostics",
    version: 1,
    at: new Date(input.now ?? Date.now()).toISOString(),
    build: input.buildId,
    userAgent: input.userAgent,
    app: { phase: input.phase, status: input.status, role: input.role },
    core: core
      ? {
          phase: core.phase,
          connection: core.connection,
          storage: core.storage,
          buildId: core.buildId,
          failure: core.failure,
        }
      : null,
    panes: input.panes ?? [],
    measures: input.measures ?? [],
    logs: (input.logs ?? []).map((record) => ({
      t: record.timestamp,
      level: record.level,
      scope: record.scope,
      event: record.event,
      ...(record.fields ? { fields: record.fields } : {}),
    })),
  }
  return JSON.stringify(report, null, 2)
}
