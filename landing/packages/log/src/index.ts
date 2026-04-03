export type LogLevel = "error" | "warn" | "info" | "debug" | "trace"

const levelOrder: Record<LogLevel, number> = {
  error: 0,
  warn: 1,
  info: 2,
  debug: 3,
  trace: 4,
}

export type LogSink = {
  error: (...args: unknown[]) => void
  warn: (...args: unknown[]) => void
  info: (...args: unknown[]) => void
  debug: (...args: unknown[]) => void
  trace: (...args: unknown[]) => void
}

const defaultSink: LogSink = {
  error: (...args) => console.error(...args),
  warn: (...args) => console.warn(...args),
  info: (...args) => console.info(...args),
  debug: (...args) => console.debug(...args),
  trace: (...args) => console.debug(...args),
}

export class Log {
  private scope: string
  private level: LogLevel
  private sink: LogSink

  constructor(scope: string, level: LogLevel = "info", sink: LogSink = defaultSink) {
    this.scope = scope
    this.level = level
    this.sink = sink
  }

  withLevel(level: LogLevel) {
    return new Log(this.scope, level, this.sink)
  }

  withScope(scope: string) {
    return new Log(`${this.scope}.${scope}`, this.level, this.sink)
  }

  trace(...args: unknown[]) {
    this.log("trace", ...args)
  }

  debug(...args: unknown[]) {
    this.log("debug", ...args)
  }

  info(...args: unknown[]) {
    this.log("info", ...args)
  }

  warn(...args: unknown[]) {
    this.log("warn", ...args)
  }

  error(...args: unknown[]) {
    this.log("error", ...args)
  }

  private log(level: LogLevel, ...args: unknown[]) {
    if (levelOrder[level] > levelOrder[this.level]) return
    this.sink[level](`[${this.scope}]`, ...args)
  }
}
