import { Elysia, t } from "elysia"
import { TMakeApiResponse } from "@in/server/controllers/v1/helpers"
import { authenticate } from "@in/server/controllers/plugins"
import { encodeGetMe, getMe } from "@in/server/methods/getMe"
import { TUserInfo } from "@in/server/models"

let Input = t.Object({})
let Response = t.Object({ user: TUserInfo })

export const getMeRoute = new Elysia()
  .use(authenticate)
  .get(
    "/getMe",
    async ({ query, store: { currentUserId } }) => {
      let result = encodeGetMe(await getMe(query, { currentUserId }))
      return { ok: true, ...result }
    },
    {
      query: Input,
      response: TMakeApiResponse(Response),
    },
  )
  .post(
    "/getMe",
    async ({ body, store: { currentUserId } }) => {
      let result = encodeGetMe(await getMe(body, { currentUserId }))
      return { ok: true, ...result }
    },
    {
      body: Input,
      response: TMakeApiResponse(Response),
    },
  )
