import { Elysia, t } from "elysia"
import * as arctic from "arctic"
import { getUserIdFromToken } from "../plugins"
import { Log } from "@in/server/utils/log"
import { isProd } from "@in/server/env"
import { getLinearAuthUrl } from "@in/server/libs/linear"
import { handleLinearCallback } from "./handleLinearCallback"
import { getNotionAuthUrl, handleNotionCallback } from "@in/server/libs/notion"
import { Authorize } from "@in/server/utils/authorize"

export const integrationsRouter = new Elysia({ prefix: "/integrations" })
  .get(
    "/linear/integrate",
    async ({ cookie: { token: cookieToken, state: cookieState, spaceId: cookieSpaceId }, query }) => {
      const spaceId = Number(query.spaceId)
      if (!query.token) return Response.json({ error: "Token is required" }, { status: 400 })
      if (isNaN(spaceId)) return Response.json({ error: "spaceId is required" }, { status: 400 })

      try {
        const { userId } = await getUserIdFromToken(query.token)
        await Authorize.spaceAdmin(spaceId, userId)
        Log.shared.info("Starting Linear OAuth integrate", { userId, spaceId })
      } catch (error) {
        Log.shared.warn("Linear OAuth integrate unauthorized", { spaceId, error })
        return Response.json({ error: "Unauthorized" }, { status: 401 })
      }

      const state = arctic.generateState()
      const secure = isProd

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
    async ({ query, cookie: { token: cookieToken, state: cookieState, spaceId: cookieSpaceId } }) => {
      const secure = isProd

      const clearCookies = () => {
        cookieState.set({ secure, path: "/", httpOnly: true, maxAge: 0, value: "", sameSite: "lax" })
        cookieToken.set({ secure, path: "/", httpOnly: true, maxAge: 0, value: "", sameSite: "lax" })
        cookieSpaceId.set({ secure, path: "/", httpOnly: true, maxAge: 0, value: "", sameSite: "lax" })
      }

      if (!cookieToken.value || !cookieState.value || !cookieSpaceId.value) {
        Log.shared.warn("Linear OAuth callback missing cookies")
        clearCookies()
        return Response.redirect("in://integrations/linear?success=false&error=missing_cookie")
      }

      if (query.state !== cookieState.value) {
        Log.shared.warn("Linear OAuth callback state mismatch", { expected: cookieState.value, got: query.state })
        clearCookies()
        return Response.redirect("in://integrations/linear?success=false&error=state_mismatch")
      }

      const spaceId = Number(cookieSpaceId.value)
      if (isNaN(spaceId)) {
        Log.shared.warn("Linear OAuth callback invalid spaceId cookie", { value: cookieSpaceId.value })
        clearCookies()
        return Response.redirect("in://integrations/linear?success=false&error=invalid_space")
      }

      let userId: number
      try {
        ;({ userId } = await getUserIdFromToken(cookieToken.value))
        await Authorize.spaceAdmin(spaceId, userId)
      } catch (error) {
        Log.shared.warn("Linear OAuth callback unauthorized", { spaceId, error })
        clearCookies()
        return Response.redirect("in://integrations/linear?success=false&error=unauthorized")
      }

      const result = await handleLinearCallback({
        code: query.code,
        userId,
        spaceId: cookieSpaceId.value,
      })

      clearCookies()

      if (!result.ok) {
        const errorValue = typeof result.error === "string" && result.error.length > 0 ? result.error : "callback_failed"
        Log.shared.error("Linear callback failed", { error: errorValue })
        return Response.redirect(`in://integrations/linear?success=false&error=${encodeURIComponent(errorValue)}`)
      }

      Log.shared.info("Linear OAuth callback succeeded", { userId, spaceId })
      return Response.redirect("in://integrations/linear?success=true")
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
    async ({ cookie: { token: cookieToken, state: cookieState, spaceId: cookieSpaceId }, query }) => {
      const spaceId = Number(query.spaceId)
      if (!query.token) return Response.json({ error: "Token is required" }, { status: 400 })
      if (isNaN(spaceId)) return Response.json({ error: "spaceId is required" }, { status: 400 })

      try {
        const { userId } = await getUserIdFromToken(query.token)
        await Authorize.spaceAdmin(spaceId, userId)
        Log.shared.info("Starting Notion OAuth integrate", { userId, spaceId })
      } catch (error) {
        Log.shared.warn("Notion OAuth integrate unauthorized", { spaceId, error })
        return Response.json({ error: "Unauthorized" }, { status: 401 })
      }

      const state = arctic.generateState()
      const secure = isProd

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
    async ({ query, cookie: { token: cookieToken, state: cookieState, spaceId: cookieSpaceId } }) => {
      const secure = isProd

      const clearCookies = () => {
        cookieState.set({ secure, path: "/", httpOnly: true, maxAge: 0, value: "", sameSite: "lax" })
        cookieToken.set({ secure, path: "/", httpOnly: true, maxAge: 0, value: "", sameSite: "lax" })
        cookieSpaceId.set({ secure, path: "/", httpOnly: true, maxAge: 0, value: "", sameSite: "lax" })
      }

      if (!cookieToken.value || !cookieState.value || !cookieSpaceId.value) {
        Log.shared.warn("Notion OAuth callback missing cookies")
        clearCookies()
        return Response.redirect("in://integrations/notion?success=false&error=missing_cookie")
      }

      if (query.state !== cookieState.value) {
        Log.shared.warn("Notion OAuth callback state mismatch", { expected: cookieState.value, got: query.state })
        clearCookies()
        return Response.redirect("in://integrations/notion?success=false&error=state_mismatch")
      }

      const spaceId = Number(cookieSpaceId.value)
      if (isNaN(spaceId)) {
        Log.shared.warn("Notion OAuth callback invalid spaceId cookie", { value: cookieSpaceId.value })
        clearCookies()
        return Response.redirect("in://integrations/notion?success=false&error=invalid_space")
      }

      let userId: number
      try {
        ;({ userId } = await getUserIdFromToken(cookieToken.value))
        await Authorize.spaceAdmin(spaceId, userId)
      } catch (error) {
        Log.shared.warn("Notion OAuth callback unauthorized", { spaceId, error })
        clearCookies()
        return Response.redirect("in://integrations/notion?success=false&error=unauthorized")
      }

      const result = await handleNotionCallback({
        code: query.code,
        userId,
        spaceId: cookieSpaceId.value,
      })

      clearCookies()

      if (!result.ok) {
        Log.shared.error("Notion callback failed", result.error)
        return Response.redirect("in://integrations/notion?success=false&error=callback_failed")
      }

      Log.shared.info("Notion OAuth callback succeeded", { userId, spaceId })
      return Response.redirect("in://integrations/notion?success=true")
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
