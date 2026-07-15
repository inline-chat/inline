import { Effect, Schema } from "effect"
import { InvalidInputError } from "../types"

export type DecodeOptions = {
  readonly field?: string
}

/** Decode untrusted input without carrying raw values or parser diagnostics into the domain error channel. */
export const decodeUnknown = <S extends Schema.Top>(schema: S, options: DecodeOptions = {}) => {
  const decode = Schema.decodeUnknownEffect(schema)

  return (input: unknown): Effect.Effect<S["Type"], InvalidInputError, S["DecodingServices"]> =>
    decode(input).pipe(Effect.mapError(() => new InvalidInputError(options)))
}
