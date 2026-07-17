import { Schema } from "effect"
import { HttpApiSchema } from "effect/unstable/httpapi"
import {
  HttpStatusCode,
  UnixSeconds,
  WireNonNegativeInteger,
  WirePositiveInteger,
  WireSafeInteger,
} from "../../core/schema/scalars"

const OptionalString = Schema.optionalKey(Schema.String)

const DeviceMetadata = {
  deviceId: OptionalString,
  clientType: OptionalString,
  clientVersion: OptionalString,
  osVersion: OptionalString,
  deviceName: OptionalString,
} as const

export const SendSmsCodeInput = Schema.Struct({
  phoneNumber: Schema.String,
  ...DeviceMetadata,
}).annotate({
  identifier: "SendSmsCodeInput",
})

export type SendSmsCodeInput = typeof SendSmsCodeInput.Type

export const SendSmsCodeResult = Schema.Struct({
  existingUser: Schema.Boolean,
  needsInviteCode: Schema.Boolean,
  phoneNumber: Schema.String,
  formattedPhoneNumber: Schema.String,
}).annotate({
  identifier: "SendSmsCodeResult",
})

export type SendSmsCodeResult = typeof SendSmsCodeResult.Type

export const VerifySmsCodeInput = Schema.Struct({
  phoneNumber: Schema.String,
  code: Schema.String,
  inviteCode: OptionalString,
  ...DeviceMetadata,
  timezone: OptionalString,
}).annotate({
  identifier: "VerifySmsCodeInput",
})

export type VerifySmsCodeInput = typeof VerifySmsCodeInput.Type

export const SendEmailCodeInput = Schema.Struct({
  email: Schema.String,
  ...DeviceMetadata,
}).annotate({
  identifier: "SendEmailCodeInput",
})

export type SendEmailCodeInput = typeof SendEmailCodeInput.Type

export const SendEmailCodeResult = Schema.Struct({
  existingUser: Schema.Boolean,
  needsInviteCode: Schema.Boolean,
  challengeToken: OptionalString,
}).annotate({
  identifier: "SendEmailCodeResult",
})

export type SendEmailCodeResult = typeof SendEmailCodeResult.Type

export const VerifyEmailCodeInput = Schema.Struct({
  email: Schema.String,
  code: Schema.String,
  challengeToken: OptionalString,
  inviteCode: OptionalString,
  ...DeviceMetadata,
  timezone: OptionalString,
}).annotate({
  identifier: "VerifyEmailCodeInput",
})

export type VerifyEmailCodeInput = typeof VerifyEmailCodeInput.Type

export const CheckInviteCodeInput = Schema.Struct({
  inviteCode: Schema.String.check(Schema.isMaxLength(64)),
}).annotate({
  identifier: "CheckInviteCodeInput",
})

export type CheckInviteCodeInput = typeof CheckInviteCodeInput.Type

export const CheckInviteCodeResult = Schema.Struct({
  valid: Schema.Boolean,
}).annotate({
  identifier: "CheckInviteCodeResult",
})

export type CheckInviteCodeResult = typeof CheckInviteCodeResult.Type

export const LogoutInput = Schema.Struct({}).annotate({
  identifier: "LogoutInput",
})

const NullableOptionalString = Schema.optionalKey(
  Schema.NullOr(Schema.String),
)
const NullableOptionalBoolean = Schema.optionalKey(
  Schema.NullOr(Schema.Boolean),
)
const NullableOptionalInteger = Schema.optionalKey(
  Schema.NullOr(WireSafeInteger),
)

export const UserPhoto = Schema.Struct({
  fileUniqueId: Schema.String,
  width: WireNonNegativeInteger,
  height: WireNonNegativeInteger,
  fileSize: WireNonNegativeInteger,
  mimeType: Schema.String,
  thumbSize: Schema.optionalKey(
    Schema.NullOr(Schema.Literals(["i", "s", "m", "h"])),
  ),
  bytes: NullableOptionalString,
  temporaryUrl: NullableOptionalString,
}).annotate({
  identifier: "UserPhoto",
})

export const UserInfo = Schema.Struct({
  id: WirePositiveInteger,
  firstName: NullableOptionalString,
  lastName: NullableOptionalString,
  bio: NullableOptionalString,
  username: NullableOptionalString,
  email: NullableOptionalString,
  phoneNumber: NullableOptionalString,
  pendingSetup: NullableOptionalBoolean,
  online: NullableOptionalBoolean,
  lastOnline: NullableOptionalInteger,
  timeZone: NullableOptionalString,
  date: UnixSeconds,
  photo: Schema.optionalKey(Schema.NullOr(Schema.Array(UserPhoto))),
}).annotate({
  identifier: "UserInfo",
})

export const LoginSessionResult = Schema.Struct({
  userId: WirePositiveInteger,
  token: Schema.String,
  user: UserInfo,
}).annotate({
  identifier: "LoginSessionResult",
})

export type LoginSessionResult = typeof LoginSessionResult.Type

export const IdentityApiError = Schema.Struct({
  ok: Schema.Literal(false),
  error: Schema.String,
  errorCode: Schema.optionalKey(HttpStatusCode),
  description: Schema.optionalKey(Schema.String),
}).annotate({
  identifier: "IdentityApiError",
})

export type IdentityApiError = typeof IdentityApiError.Type

export const identityApiErrorAt = (status: number) =>
  IdentityApiError.pipe(HttpApiSchema.status(status))

export const identitySuccess = <Result extends Schema.Top>(
  result: Result,
) =>
  Schema.Struct({
    ok: Schema.Literal(true),
    result,
  })

export const IdentityLogoutSuccess = Schema.Struct({
  ok: Schema.Literal(true),
}).annotate({
  identifier: "IdentityLogoutSuccess",
})
