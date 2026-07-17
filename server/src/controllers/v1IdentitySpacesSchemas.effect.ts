import { Schema } from "effect"
import { HttpApiSchema } from "effect/unstable/httpapi"
import {
  HttpStatusCode,
  UnixSeconds,
  WireNonNegativeInteger,
  WirePositiveInteger,
  WireSafeInteger,
} from "../core/schema/scalars"
import { UserInfo, UserPhoto } from "../modules/auth/identitySchemas.effect"

const OptionalString = Schema.optionalKey(Schema.String)
const NullableOptionalString = Schema.optionalKey(Schema.NullOr(Schema.String))
const NullableOptionalBoolean = Schema.optionalKey(Schema.NullOr(Schema.Boolean))
const NullableOptionalInteger = Schema.optionalKey(Schema.NullOr(WireSafeInteger))

/** Legacy `/v1` IDs accept either a JSON integer or its string form. */
export const V1InputId = Schema.Union([Schema.String, WireSafeInteger]).annotate({
  identifier: "V1InputId",
  description: "An Inline entity identifier supplied as an integer or string",
})

export const MinUserInfo = Schema.Struct({
  id: WirePositiveInteger,
  firstName: NullableOptionalString,
  lastName: NullableOptionalString,
  username: NullableOptionalString,
  online: NullableOptionalBoolean,
  lastOnline: NullableOptionalInteger,
  pendingSetup: NullableOptionalBoolean,
  date: UnixSeconds,
  photo: Schema.optionalKey(Schema.NullOr(Schema.Array(UserPhoto))),
}).annotate({
  identifier: "MinUserInfo",
})

export const SpaceInfo = Schema.Struct({
  id: WirePositiveInteger,
  name: Schema.String,
  handle: NullableOptionalString,
  date: UnixSeconds,
  creator: Schema.Boolean,
  isPublic: Schema.Boolean,
}).annotate({
  identifier: "SpaceInfo",
})

export const MemberInfo = Schema.Struct({
  id: WirePositiveInteger,
  userId: WirePositiveInteger,
  spaceId: WirePositiveInteger,
  role: Schema.Literals(["owner", "admin", "member"]),
  date: UnixSeconds,
}).annotate({
  identifier: "MemberInfo",
})

export const PeerInfo = Schema.Union([
  Schema.Struct({ userId: WirePositiveInteger }),
  Schema.Struct({ threadId: WirePositiveInteger }),
]).annotate({
  identifier: "PeerInfo",
})

export const ChatInfo = Schema.Struct({
  id: WirePositiveInteger,
  type: Schema.Literals(["private", "thread"]),
  peer: PeerInfo,
  lastMsgId: NullableOptionalInteger,
  date: UnixSeconds,
  title: NullableOptionalString,
  spaceId: NullableOptionalInteger,
  publicThread: NullableOptionalBoolean,
  threadNumber: NullableOptionalInteger,
  number: NullableOptionalInteger,
  emoji: NullableOptionalString,
}).annotate({
  identifier: "ChatInfo",
})

export const DialogInfo = Schema.Struct({
  peerId: PeerInfo,
  chatId: NullableOptionalInteger,
  pinned: NullableOptionalBoolean,
  spaceId: NullableOptionalInteger,
  unreadCount: NullableOptionalInteger,
  readInboxMaxId: NullableOptionalInteger,
  draft: NullableOptionalString,
  archived: NullableOptionalBoolean,
  open: NullableOptionalBoolean,
  openedDate: NullableOptionalInteger,
  order: NullableOptionalString,
  pinnedOrder: NullableOptionalString,
  sidebarVisible: NullableOptionalBoolean,
  chatListHidden: NullableOptionalBoolean,
}).annotate({
  identifier: "DialogInfo",
})

export const CheckUsernameInput = Schema.Struct({
  username: Schema.String,
}).annotate({
  identifier: "CheckUsernameInput",
})
export type CheckUsernameInput = typeof CheckUsernameInput.Type

export const CheckUsernameResult = Schema.Struct({
  available: Schema.Boolean,
}).annotate({
  identifier: "CheckUsernameResult",
})
export type CheckUsernameResult = typeof CheckUsernameResult.Type

export const GetMeInput = Schema.Struct({}).annotate({
  identifier: "GetMeInput",
})
export type GetMeInput = typeof GetMeInput.Type

export const GetMeResult = Schema.Struct({
  user: UserInfo,
}).annotate({
  identifier: "GetMeResult",
})
export type GetMeResult = typeof GetMeResult.Type

export const GetUserInput = Schema.Struct({
  id: V1InputId,
}).annotate({
  identifier: "GetUserInput",
})
export type GetUserInput = typeof GetUserInput.Type

export const GetUserResult = Schema.Struct({
  user: MinUserInfo,
}).annotate({
  identifier: "GetUserResult",
})
export type GetUserResult = typeof GetUserResult.Type

export const SearchContactsInput = Schema.Struct({
  q: Schema.String,
  limit: Schema.optionalKey(WireSafeInteger),
}).annotate({
  identifier: "SearchContactsInput",
})
export type SearchContactsInput = typeof SearchContactsInput.Type

export const SearchContactsResult = Schema.Struct({
  users: Schema.Array(MinUserInfo),
}).annotate({
  identifier: "SearchContactsResult",
})
export type SearchContactsResult = typeof SearchContactsResult.Type

export const UpdateProfileInput = Schema.Struct({
  firstName: OptionalString,
  lastName: OptionalString,
  bio: OptionalString,
  username: OptionalString,
  timeZone: OptionalString,
}).annotate({
  identifier: "UpdateProfileInput",
})
export type UpdateProfileInput = typeof UpdateProfileInput.Type

export const UpdateProfileResult = Schema.Struct({
  user: UserInfo,
}).annotate({
  identifier: "UpdateProfileResult",
})
export type UpdateProfileResult = typeof UpdateProfileResult.Type

export const UpdateProfilePhotoInput = Schema.Struct({
  fileUniqueId: Schema.String,
}).annotate({
  identifier: "UpdateProfilePhotoInput",
})
export type UpdateProfilePhotoInput = typeof UpdateProfilePhotoInput.Type

export const UpdateProfilePhotoResult = Schema.Struct({
  user: UserInfo,
}).annotate({
  identifier: "UpdateProfilePhotoResult",
})
export type UpdateProfilePhotoResult = typeof UpdateProfilePhotoResult.Type

export const UpdateStatusInput = Schema.Struct({
  online: Schema.Boolean,
}).annotate({
  identifier: "UpdateStatusInput",
})
export type UpdateStatusInput = typeof UpdateStatusInput.Type

export const UpdateStatusResult = Schema.Struct({
  online: Schema.Boolean,
  // The retained method currently exposes Date#getTime(), so this is
  // milliseconds even though most Inline timestamps use seconds.
  lastOnline: Schema.optionalKey(Schema.NullOr(WireNonNegativeInteger)),
}).annotate({
  identifier: "UpdateStatusResult",
})
export type UpdateStatusResult = typeof UpdateStatusResult.Type

export const CreateSpaceInput = Schema.Struct({
  name: Schema.String,
  handle: OptionalString,
}).annotate({
  identifier: "CreateSpaceInput",
})
export type CreateSpaceInput = typeof CreateSpaceInput.Type

export const CreateSpaceResult = Schema.Struct({
  space: SpaceInfo,
  member: MemberInfo,
  chats: Schema.Array(ChatInfo),
  dialogs: Schema.Array(DialogInfo),
}).annotate({
  identifier: "CreateSpaceResult",
})
export type CreateSpaceResult = typeof CreateSpaceResult.Type

export const DeleteSpaceInput = Schema.Struct({
  spaceId: V1InputId,
}).annotate({
  identifier: "DeleteSpaceInput",
})
export type DeleteSpaceInput = typeof DeleteSpaceInput.Type

export const GetSpacesInput = Schema.Struct({}).annotate({
  identifier: "GetSpacesInput",
})
export type GetSpacesInput = typeof GetSpacesInput.Type

export const GetSpacesResult = Schema.Struct({
  spaces: Schema.Array(SpaceInfo),
  members: Schema.Array(MemberInfo),
}).annotate({
  identifier: "GetSpacesResult",
})
export type GetSpacesResult = typeof GetSpacesResult.Type

export const GetSpaceInput = Schema.Struct({
  id: V1InputId,
}).annotate({
  identifier: "GetSpaceInput",
})
export type GetSpaceInput = typeof GetSpaceInput.Type

export const GetSpaceResult = Schema.Struct({
  space: SpaceInfo,
  members: Schema.Array(MemberInfo),
}).annotate({
  identifier: "GetSpaceResult",
})
export type GetSpaceResult = typeof GetSpaceResult.Type

export const GetInviteCodesInput = Schema.Struct({}).annotate({
  identifier: "GetInviteCodesInput",
})
export type GetInviteCodesInput = typeof GetInviteCodesInput.Type

export const InviteCodeInfo = Schema.Struct({
  code: Schema.String,
  redeemed: Schema.Boolean,
  redeemedAt: OptionalString,
}).annotate({
  identifier: "InviteCodeInfo",
})

export const GetInviteCodesResult = Schema.Struct({
  codes: Schema.Array(InviteCodeInfo),
}).annotate({
  identifier: "GetInviteCodesResult",
})
export type GetInviteCodesResult = typeof GetInviteCodesResult.Type

export const AddMemberInput = Schema.Struct({
  spaceId: V1InputId,
  userId: V1InputId,
}).annotate({
  identifier: "AddMemberInput",
})
export type AddMemberInput = typeof AddMemberInput.Type

export const AddMemberResult = Schema.Struct({
  member: MemberInfo,
}).annotate({
  identifier: "AddMemberResult",
})
export type AddMemberResult = typeof AddMemberResult.Type

export const LeaveSpaceInput = Schema.Struct({
  spaceId: V1InputId,
}).annotate({
  identifier: "LeaveSpaceInput",
})
export type LeaveSpaceInput = typeof LeaveSpaceInput.Type

export const LeaveSpaceResult = Schema.Struct({
  memberId: WirePositiveInteger,
  userId: WirePositiveInteger,
}).annotate({
  identifier: "LeaveSpaceResult",
})
export type LeaveSpaceResult = typeof LeaveSpaceResult.Type

export const GetSpaceMembersInput = Schema.Struct({
  spaceId: V1InputId,
}).annotate({
  identifier: "GetSpaceMembersInput",
})
export type GetSpaceMembersInput = typeof GetSpaceMembersInput.Type

export const GetSpaceMembersResult = Schema.Struct({
  members: Schema.Array(MemberInfo),
  users: Schema.Array(MinUserInfo),
}).annotate({
  identifier: "GetSpaceMembersResult",
})
export type GetSpaceMembersResult = typeof GetSpaceMembersResult.Type

export const SavePushNotificationInput = Schema.Struct({
  applePushToken: Schema.String,
}).annotate({
  identifier: "SavePushNotificationInput",
})
export type SavePushNotificationInput = typeof SavePushNotificationInput.Type

export const V1IdentitySpacesApiError = Schema.Struct({
  ok: Schema.Literal(false),
  error: Schema.String,
  errorCode: Schema.optionalKey(HttpStatusCode),
  description: Schema.optionalKey(Schema.String),
}).annotate({
  identifier: "V1IdentitySpacesApiError",
})

export const v1IdentitySpacesApiErrorAt = (status: number) =>
  V1IdentitySpacesApiError.pipe(HttpApiSchema.status(status))

export const v1IdentitySpacesSuccess = <Result extends Schema.Top>(result: Result) =>
  Schema.Struct({
    ok: Schema.Literal(true),
    result,
  })

export const V1IdentitySpacesEmptySuccess = Schema.Struct({
  ok: Schema.Literal(true),
}).annotate({
  identifier: "V1IdentitySpacesEmptySuccess",
})
