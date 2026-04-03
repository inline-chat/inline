export type TransactionError =
  | { kind: "rpc-error"; code?: number; message?: string }
  | { kind: "timeout" }
  | { kind: "invalid" }
  | { kind: "not-connected" }
  | { kind: "stopped" }

export class TransactionFailure extends Error {
  readonly kind: TransactionError["kind"]
  readonly code?: number

  constructor(error: TransactionError) {
    super(error.kind)
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
  stopped: (): TransactionError => ({ kind: "stopped" }),
}
