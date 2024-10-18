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
}
