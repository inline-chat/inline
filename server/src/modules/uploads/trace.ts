import { LogLevel } from "@in/server/utils/log"

/** Enable only the existing upload request timings for a bounded measurement. */
export const uploadTraceLogLevel = (
  env: Readonly<Record<string, string | undefined>> = process.env,
): LogLevel | undefined => env["INLINE_UPLOAD_TRACE"] === "1" ? LogLevel.DEBUG : undefined
