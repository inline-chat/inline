import { db } from "@in/server/db"
import { and, eq, or } from "drizzle-orm"
import { linkEmbed_experimental, users } from "@in/server/db/schema"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { type Static, Type } from "@sinclair/typebox"
import type { HandlerContext } from "@in/server/controllers/helpers"
import { encodeFullUserInfo, encodeMinUserInfo, encodeUserInfo, TMinUserInfo, TUserInfo } from "../api-types"
import { TInputId } from "@in/server/types/methods"


export const Input = Type.Object({

})

export const Response = Type.Object({
//   linkEmbeds: Type.Array(),
})

export const handler = async (input: Static<typeof Input>, _: HandlerContext): Promise<Static<typeof Response>> => {
let emebeds = await db.select().from(linkEmbed_experimental)

return { linkEmbeds: emebeds }
}
