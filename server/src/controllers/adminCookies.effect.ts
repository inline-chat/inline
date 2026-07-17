import {
  Duration,
} from "effect"
import {
  HttpApiBuilder,
  HttpApiSecurity,
} from "effect/unstable/httpapi"
import {
  ADMIN_COOKIE_MAX_AGE,
} from "./adminSecurityPolicy.effect"
import {
  AdminCookieName,
} from "./adminSchemas.effect"

const isProduction = () =>
  process.env.NODE_ENV === "production"

export interface AdminSessionCookieDirective {
  readonly value: string
  readonly maxAgeSeconds: number
}

export const AdminSessionSecurity =
  HttpApiSecurity.apiKey({
    in: "cookie",
    key: AdminCookieName,
  })

export const adminSessionCookie = (
  token: string,
): AdminSessionCookieDirective => ({
  value: token,
  maxAgeSeconds: ADMIN_COOKIE_MAX_AGE,
})

export const clearedAdminSessionCookie =
  (): AdminSessionCookieDirective => ({
    value: "",
    maxAgeSeconds: 0,
  })

export const applyAdminSessionCookie = (
  directive: AdminSessionCookieDirective,
) =>
  HttpApiBuilder.securitySetCookie(
    AdminSessionSecurity,
    directive.value,
    {
      httpOnly: true,
      secure: isProduction(),
      sameSite: "strict",
      path: "/",
      maxAge: Duration.seconds(
        directive.maxAgeSeconds,
      ),
    },
  )
