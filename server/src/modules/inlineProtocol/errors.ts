import { Data } from "effect"

export class InlineProtocolConfigurationError extends Data.TaggedError(
  "InlineProtocolConfigurationError",
)<{ readonly reason: string; readonly cause?: unknown }> {
  override readonly message = "Inline Protocol configuration is invalid."
}

export class InlineProtocolKeyStoreError extends Data.TaggedError(
  "InlineProtocolKeyStoreError",
)<{ readonly operation: string; readonly cause?: unknown }> {
  override readonly message = "Inline Protocol authorization-key storage failed."
}

export class InlineProtocolReplayError extends Data.TaggedError(
  "InlineProtocolReplayError",
)<{ readonly operation: string; readonly cause?: unknown }> {
  override readonly message = "Inline Protocol replay protection failed."
}

export class InlineProtocolFailure extends Data.TaggedError(
  "InlineProtocolFailure",
)<{ readonly phase: string; readonly cause?: unknown }> {
  override readonly message = "Inline Protocol connection failed."
}
