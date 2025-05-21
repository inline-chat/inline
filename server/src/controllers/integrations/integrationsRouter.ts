import { Elysia, t } from "elysia"
import * as arctic from "arctic"
import { getUserIdFromToken } from "../plugins"
import { Log } from "@in/server/utils/log"
import { getLinearAuthUrl } from "@in/server/libs/linear"
import { handleLinearCallback } from "./handleLinearCallback"
import { getNotionAuthUrl, handleNotionCallback } from "@in/server/libs/notion"

export const integrationsRouter = new Elysia({ prefix: "/integrations" })
  .get(
    "/linear/integrate",
    ({ cookie: { token: cookieToken, state: cookieState, spaceId: cookieSpaceId }, query }) => {
      if (!query.token) {
        return Response.json({ error: "Token is required" }, { status: 400 })
      }

      const state = arctic.generateState()
      const secure = process.env.NODE_ENV === "production" ? true : false

      cookieState.set({
        secure,
        path: "/",
        httpOnly: true,
        maxAge: 60 * 10,
        value: state,
        sameSite: "lax",
      })

      cookieToken.set({
        secure,
        path: "/",
        httpOnly: true,
        maxAge: 60 * 10,
        value: query.token,
        // tells browsers that the cookie should be sent when users navigate from external links
        sameSite: "lax",
      })

      cookieSpaceId.set({
        secure,
        path: "/",
        httpOnly: true,
        maxAge: 60 * 10,
        value: query.spaceId,
        sameSite: "lax",
      })

      const { url } = getLinearAuthUrl(state)
      if (!url) {
        return Response.json({ error: "Linear auth URL not found" }, { status: 500 })
      }
      return Response.redirect(url)
    },
    {
      cookie: t.Cookie({
        token: t.Optional(t.String()),
        state: t.Optional(t.String()),
        spaceId: t.Optional(t.String()),
      }),
      query: t.Object({
        token: t.String(),
        spaceId: t.String(),
      }),
    },
  )
  .get(
    "/linear/callback",
    async ({ query, cookie: { token: cookieToken, state: cookieState, spaceId: cookieSpaceId }, headers }) => {
      if (!cookieToken.value || !cookieState.value || !cookieSpaceId.value) {
        Log.shared.error("Linear cookie missing")
      } else {
        const { userId } = await getUserIdFromToken(cookieToken.value)

        const result = await handleLinearCallback({
          code: query.code,
          userId,
          spaceId: cookieSpaceId.value,
        })

        if (!result.ok) {
          Log.shared.error("Linear callback failed", result.error)
          return "internal server error, contact mo@inline.chat"
        } else {
          return Response.redirect("in://integrations/linear?success=true")
        }
      }
    },
    {
      cookie: t.Cookie({
        token: t.Optional(t.String()),
        state: t.Optional(t.String()),
        spaceId: t.Optional(t.String()),
      }),
      query: t.Object({
        code: t.String(),
        state: t.String(),
      }),
    },
  )
  .get(
    "/notion/integrate",
    ({ cookie: { token: cookieToken, state: cookieState, spaceId: cookieSpaceId }, query }) => {
      if (!query.token) {
        return Response.json({ error: "Token is required" }, { status: 400 })
      }

      const state = arctic.generateState()
      const secure = process.env.NODE_ENV === "production" ? true : false

      cookieState.set({
        secure,
        path: "/",
        httpOnly: true,
        maxAge: 60 * 10,
        value: state,
        sameSite: "lax",
      })

      cookieToken.set({
        secure,
        path: "/",
        httpOnly: true,
        maxAge: 60 * 10,
        value: query.token,
        // tells browsers that the cookie should be sent when users navigate from external links
        sameSite: "lax",
      })

      cookieSpaceId.set({
        secure,
        path: "/",
        httpOnly: true,
        maxAge: 60 * 10,
        value: query.spaceId,
        sameSite: "lax",
      })

      const { url } = getNotionAuthUrl(state)
      if (!url) {
        return Response.json({ error: "Notion auth URL not found" }, { status: 500 })
      }
      return Response.redirect(url)
    },
    {
      cookie: t.Cookie({
        token: t.Optional(t.String()),
        state: t.Optional(t.String()),
        spaceId: t.Optional(t.String()),
      }),
      query: t.Object({
        token: t.String(),
        spaceId: t.String(),
      }),
    },
  )
  .get(
    "/notion/callback",
    async ({ query, cookie: { token: cookieToken, state: cookieState, spaceId: cookieSpaceId }, headers }) => {
      if (!cookieToken.value || !cookieState.value || !cookieSpaceId.value) {
        Log.shared.error("Notion cookie missing")
      } else {
        const { userId } = await getUserIdFromToken(cookieToken.value)

        const result = await handleNotionCallback({
          code: query.code,
          userId,
          spaceId: cookieSpaceId.value,
        })

        if (!result.ok) {
          Log.shared.error("Notion callback failed", result.error)
          return "internal server error, contact mo@inline.chat"
        } else {
          return Response.redirect("in://integrations/notion?success=true")
        }
      }
    },
    {
      cookie: t.Cookie({
        token: t.Optional(t.String()),
        state: t.Optional(t.String()),
        spaceId: t.Optional(t.String()),
      }),
      query: t.Object({
        code: t.String(),
        state: t.String(),
      }),
    },
  )
