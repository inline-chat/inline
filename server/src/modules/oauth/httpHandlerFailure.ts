/**
 * Preserves an established OAuth response while carrying the private defect
 * that produced it to the transport's single reporting boundary.
 */
export class OAuthHandlerFailure extends Error {
  readonly cause: unknown
  readonly response: Response

  constructor(
    message: string,
    options: {
      readonly cause: unknown
      readonly response: Response
    },
  ) {
    super(message)
    this.name = "OAuthHandlerFailure"
    this.cause = options.cause
    this.response = options.response
  }
}
