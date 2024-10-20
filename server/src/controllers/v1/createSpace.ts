import { Elysia, t } from "elysia"
import { createSpace, encodeCreateSpace } from "@in/server/methods/createSpace"
import { TChatInfo, TMemberInfo, TSpaceInfo } from "@in/server/models"
import { TMakeApiResponse } from "@in/server/controllers/v1/helpers"
import { authenticate } from "@in/server/controllers/plugins"

let Input = t.Object({
  name: t.String(),
  handle: t.Optional(t.String()),
})
let Response = t.Object({
  space: TSpaceInfo,
  member: TMemberInfo,
  chats: t.Array(TChatInfo),
})

export const createSpaceRoute = new Elysia()
  .use(authenticate)
  .get(
    "/createSpace",
    async ({ query, store: { currentUserId } }) => {
      let result = encodeCreateSpace(
        await createSpace(query, { currentUserId }),
      )
      return { ok: true, ...result }
    },
    {
      query: Input,
      response: TMakeApiResponse(Response),
    },
  )
  .post(
    "/createSpace",
    async ({ body, store: { currentUserId } }) => {
      let result = encodeCreateSpace(await createSpace(body, { currentUserId }))
      return { ok: true, ...result }
    },
    {
      body: Input,
      response: TMakeApiResponse(Response),
    },
  )
