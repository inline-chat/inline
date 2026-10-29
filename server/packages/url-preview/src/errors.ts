export class UrlPreviewError extends Error {
  constructor(message: string, public readonly code: string, public readonly status?: number) {
    super(message)
    this.name = "UrlPreviewError"
  }
}
