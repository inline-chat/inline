import {
  Option,
  Schema,
} from "effect"

export const MAX_REALTIME_METADATA_LENGTH = 200

/** Process-local identity assigned at the raw WebSocket transport boundary. */
export const RealtimeConnectionId = Schema.String.check(
  Schema.isUUID(4),
).pipe(
  Schema.brand("RealtimeConnectionId"),
)

export type RealtimeConnectionId =
  typeof RealtimeConnectionId.Type

/** Bounded request metadata retained for diagnostics, never public output. */
export const RealtimeMetadataValue =
  Schema.Trim.check(
    Schema.isMinLength(1),
    Schema.isMaxLength(
      MAX_REALTIME_METADATA_LENGTH,
    ),
  ).pipe(
    Schema.brand("RealtimeMetadataValue"),
  )

export type RealtimeMetadataValue =
  typeof RealtimeMetadataValue.Type

const decodeMetadataValue =
  Schema.decodeUnknownOption(
    RealtimeMetadataValue,
  )

export const toRealtimeMetadataValue = (
  input: unknown,
): RealtimeMetadataValue | undefined => {
  if (typeof input !== "string") {
    return undefined
  }

  const trimmed = input.trim()
  if (trimmed.length === 0) {
    return undefined
  }

  const bounded = trimmed.length <=
      MAX_REALTIME_METADATA_LENGTH
    ? trimmed
    : trimmed.slice(
      0,
      MAX_REALTIME_METADATA_LENGTH,
    )

  return Option.getOrUndefined(
    decodeMetadataValue(bounded),
  )
}
