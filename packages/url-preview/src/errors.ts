export class UrlPreviewError extends Error {
  constructor(message: string, public readonly code: string) {
    super(message)
    this.name = "UrlPreviewError"
  }
}
