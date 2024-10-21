// https://effect.website/docs/guides/schema/basic-usage

import { t } from "elysia"
import {
  DbChat,
  DbMember,
  DbSpace,
  DbUser,
  type DbMessage,
} from "@in/server/db/schema"
import {
  Type,
  type Static,
  type TSchema,
  type StaticEncode,
  type StaticDecode,
} from "@sinclair/typebox"
import { Value } from "@sinclair/typebox/value"

// const BigIntString = Type.Transform(Type.BigInt())
//   .Decode((value) => String(value))
//   .Encode((value) => BigInt(value))

const Optional = <T extends TSchema>(schema: T) =>
  Type.Union([Type.Null(), Type.Undefined(), schema])

const encodeDate = (date: Date | number): number => {
  return typeof date === "number" ? date : date.getTime()
}

/// Space  -------------
export const TSpaceInfo = Type.Object({
  id: Type.Integer(),
  name: Type.String(),
  handle: Optional(Type.String()),
  date: Type.Integer(),
})
export type TSpaceInfo = StaticEncode<typeof TSpaceInfo>
export const encodeSpaceInfo = (space: DbSpace | TSpaceInfo): TSpaceInfo => {
  return Value.Encode(TSpaceInfo, {
    ...space,
    date: encodeDate(space.date),
  })
}

/// User -------------
export const TUserInfo = Type.Object({
  id: Type.Integer(),
  firstName: Optional(Type.String()),
  lastName: Optional(Type.String()),
  email: Optional(Type.String()),
  date: Type.Integer(),
})
export type TUserInfo = StaticEncode<typeof TUserInfo>
export const encodeUserInfo = (user: DbUser | TUserInfo): TUserInfo => {
  return Value.Encode(TUserInfo, {
    ...user,
    date: user.date ? encodeDate(user.date) : 0,
  })
}

// Member -------------
export const TMemberInfo = Type.Object({
  id: Type.Integer(),
  userId: Type.Integer(),
  spaceId: Type.Integer(),
  role: Type.Union([
    Type.Literal("owner"),
    Type.Literal("admin"),
    Type.Literal("member"),
  ]),
  date: Type.Integer(),
})
export type TMemberInfo = StaticEncode<typeof TMemberInfo>

export const encodeMemberInfo = (
  member: DbMember | TMemberInfo,
): TMemberInfo => {
  return Value.Encode(TMemberInfo, {
    ...member,
    date: encodeDate(member.date),
  })
}

// Chat -------------
export const TChatInfo = Type.Object({
  id: Type.Integer(),
  spaceId: Optional(Type.Integer()),
  title: Optional(Type.String()),
  date: Type.Integer(),
  threadNumber: Optional(Type.Integer()),
})
export type TChatInfo = StaticEncode<typeof TChatInfo>
export const encodeChatInfo = (chat: DbChat | TChatInfo): TChatInfo => {
  return Value.Encode(TChatInfo, {
    ...chat,
    date: encodeDate(chat.date),
    threadNumber: chat.threadNumber ? chat.threadNumber : undefined,
  })
}

// Message -------------
export const TMessageInfo = Type.Object({
  id: Type.Integer(),
  chatId: Type.Integer(),
  userId: Type.Integer(),
  content: Type.String(),
  date: Type.Integer(),
})

export type TMessageInfo = StaticEncode<typeof TMessageInfo>
export const encodeMessageInfo = (
  message: DbMessage | TMessageInfo,
): TMessageInfo => {
  return Value.Encode(TMessageInfo, {
    ...message,
    date: encodeDate(message.date),
  })
}
