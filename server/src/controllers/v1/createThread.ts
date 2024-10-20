import { Elysia, t } from "elysia"
import { TChatInfo, TMemberInfo, TSpaceInfo } from "@in/server/models"
import { TMakeApiResponse } from "@in/server/controllers/v1/helpers"
import { authenticate } from "@in/server/controllers/plugins"
import {
  createThread,
  encodeCreateThread,
} from "@in/server/methods/createThread"

let Input = t.Object({
  title: t.String(),
  spaceId: t.String(),
})
let Response = t.Object({
  chat: TChatInfo,
})

export const createThreadRoute = new Elysia()
  .use(authenticate)
  .get(
    "/createThread",
    async ({ query, store: { currentUserId } }) => {
      let result = encodeCreateThread(
        await createThread(query, { currentUserId }),
      )
      return { ok: true, ...result }
    },
    {
      query: Input,
      response: TMakeApiResponse(Response),
    },
  )
  .post(
    "/createThread",
    async ({ body, store: { currentUserId } }) => {
      let result = encodeCreateThread(
        await createThread(body, { currentUserId }),
      )
      return { ok: true, ...result }
    },
    {
      body: Input,
      response: TMakeApiResponse(Response),
    },
  )
