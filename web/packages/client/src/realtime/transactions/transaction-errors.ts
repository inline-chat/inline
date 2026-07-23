export type TransactionError =
  | { kind: "rpc-error"; code?: number; message?: string }
  | { kind: "timeout" }
  | { kind: "invalid" }
  | { kind: "not-connected" }
  | { kind: "ambiguous-result" }
  | { kind: "dependency-failed" }
  | { kind: "stopped" }

export class TransactionFailure extends Error {
  readonly kind: TransactionError["kind"]
  readonly code?: number

  constructor(error: TransactionError, options?: ErrorOptions) {
    super(error.kind, options)
    this.name = `TransactionFailure:${error.kind}`
    this.kind = error.kind
    this.code = "code" in error ? error.code : undefined
  }
}

export const TransactionErrors = {
  rpcError: (code?: number, message?: string): TransactionError => ({
    kind: "rpc-error",
    code,
    message,
  }),
  timeout: (): TransactionError => ({ kind: "timeout" }),
  invalid: (): TransactionError => ({ kind: "invalid" }),
  notConnected: (): TransactionError => ({ kind: "not-connected" }),
  ambiguousResult: (): TransactionError => ({ kind: "ambiguous-result" }),
  dependencyFailed: (): TransactionError => ({
    kind: "dependency-failed",
  }),
  stopped: (): TransactionError => ({ kind: "stopped" }),
}
