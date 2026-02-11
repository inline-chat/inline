export type InlineSdkLogger = {
  debug?: (msg: string, meta?: unknown) => void
  info?: (msg: string, meta?: unknown) => void
  warn?: (msg: string, meta?: unknown) => void
  error?: (msg: string, meta?: unknown) => void
}

export const noopLogger: InlineSdkLogger = {}

