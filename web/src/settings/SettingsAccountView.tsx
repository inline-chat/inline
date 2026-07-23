import { DbObjectKind, useRealtimeClient, type User } from "@inline/client"
import { useNavigate } from "@tanstack/react-router"
import * as stylex from "@stylexjs/stylex"
import { useState } from "react"
import { authSession, useAuthSession } from "~/inline/auth/auth-session"
import { useInlineObject } from "~/inline/data/react"
import { colors } from "../styles/tokens.stylex"
import { UserAvatar } from "~/ui/Avatar"
import { InlineButton } from "~/ui/InlineButton"
import { InlineSkeleton } from "~/ui/InlineSkeleton"
import { SettingsPage, SettingsSection } from "./SettingsSection"

export function SettingsAccountView() {
  const auth = useAuthSession()
  const realtime = useRealtimeClient()
  const navigate = useNavigate()
  const [loggingOut, setLoggingOut] = useState(false)
  const [error, setError] = useState<string>()
  const user = useInlineObject<DbObjectKind.User, User>(
    DbObjectKind.User,
    auth.currentUserId ?? undefined,
  )

  const logout = async () => {
    if (loggingOut) return
    setLoggingOut(true)
    setError(undefined)
    try {
      await realtime.stop()
      await authSession.logout()
      await navigate({ to: "/login", replace: true })
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Could not log out.")
      setLoggingOut(false)
    }
  }

  return (
    <SettingsPage title="Account">
      <SettingsSection>
        <div {...stylex.props(styles.account)}>
          {user ? (
            <>
              <UserAvatar user={user} size={48} />
              <span {...stylex.props(styles.identity)}>
                <strong {...stylex.props(styles.name)}>
                  {[user.firstName, user.lastName]
                    .filter(Boolean)
                    .join(" ") || "Inline"}
                </strong>
                <span {...stylex.props(styles.detail)}>
                  {user.email ?? (user.username ? `@${user.username}` : "")}
                </span>
              </span>
            </>
          ) : (
            <span aria-label="Loading account" {...stylex.props(styles.loading)}>
              <InlineSkeleton width={48} height={48} radius="50%" />
              <span {...stylex.props(styles.loadingLines)}>
                <InlineSkeleton width={112} height={11} radius={6} />
                <InlineSkeleton width={76} height={9} radius={5} />
              </span>
            </span>
          )}
        </div>
      </SettingsSection>
      <SettingsSection>
        <div {...stylex.props(styles.logoutRow)}>
          <span {...stylex.props(styles.logoutCopy)}>
            <strong>Log Out</strong>
            <span>Remove this account and its local session from this browser.</span>
          </span>
          <InlineButton
            variant="destructive"
            disabled={loggingOut}
            onClick={() => void logout()}
          >
            {loggingOut ? "Logging Out…" : "Log Out"}
          </InlineButton>
        </div>
      </SettingsSection>
      {error ? <p role="alert" {...stylex.props(styles.error)}>{error}</p> : null}
    </SettingsPage>
  )
}

const styles = stylex.create({
  account: {
    minHeight: 78,
    display: "flex",
    alignItems: "center",
    gap: 13,
    padding: 14,
  },
  identity: {
    minWidth: 0,
    display: "flex",
    flexDirection: "column",
    gap: 2,
  },
  name: {
    overflow: "hidden",
    fontSize: 14,
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
  },
  detail: {
    overflow: "hidden",
    color: colors.textSecondary,
    fontSize: 12,
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
  },
  loading: {
    display: "flex",
    alignItems: "center",
    gap: 13,
  },
  loadingLines: {
    display: "flex",
    flexDirection: "column",
    gap: 7,
  },
  logoutRow: {
    minHeight: 62,
    display: "flex",
    alignItems: "center",
    gap: 18,
    padding: 13,
  },
  logoutCopy: {
    minWidth: 0,
    display: "flex",
    flexDirection: "column",
    flex: 1,
    gap: 2,
    fontSize: 12,
    color: colors.textSecondary,
  },
  error: {
    margin: 0,
    color: colors.destructive,
    fontSize: 11,
  },
})
