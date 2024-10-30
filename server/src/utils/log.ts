export class Log {
  static shared = new Log("shared")

  constructor(private scope: string) {}

  error(messageOrError: string | unknown, error?: unknown | Error): void {
    if (typeof messageOrError === "string") {
      console.error(this.scope, messageOrError, error)
    } else {
      console.error(this.scope, messageOrError)
    }
  }

  warn(messageOrError: string | unknown, error?: unknown | Error): void {
    if (typeof messageOrError === "string") {
      console.warn(this.scope, messageOrError, error)
    } else {
      console.warn(this.scope, messageOrError)
    }
  }

  debug(...args: any[]): void {
    console.debug(this.scope, ...args)
  }
}
