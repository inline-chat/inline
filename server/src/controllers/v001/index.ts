import { Elysia, t } from "elysia"
import { setup } from "@in/server/setup"
import { auth } from "@in/server/controllers/v001/auth"

export const apiV001 = new Elysia({ prefix: "/v001" }).use(setup).use(auth)
