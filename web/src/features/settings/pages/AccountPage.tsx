/** Account: who is signed in, this device, and Sign Out with a plain warning about what it erases. */

import { userAvatarSeed, userDisplayName } from "@inline/chat-ui"
import { useModel, useSignal } from "@inline/reactive/react"
import { DialogController } from "@inline/ui"
import { Avatar, Button, Dialog } from "@inline/ui/react"
import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import { space } from "@inline/ui/tokens/space.stylex"
import * as stylex from "@stylexjs/stylex"
import { useState } from "react"
import { signOutWarning } from "../format"
import { Note, Row, Section } from "../Rows"
import type { SettingsModel } from "../settings-model"
import type { SettingsAccount } from "../types"

export function AccountPage(props: { model: SettingsModel; account: SettingsAccount; pendingCount: number }) {
  const me = useSignal(props.account.me)
  const dialog = useModel(() => new DialogController({ role: "alertdialog" }))
  // View-only: true while the sign-out the user confirmed is running.
  const [signingOut, setSigningOut] = useState(false)
  const name = userDisplayName(me)

  const confirm = () => {
    setSigningOut(true)
    void Promise.resolve()
      .then(() => props.account.signOut())
      .catch(() => undefined)
      .finally(() => {
        setSigningOut(false)
        dialog.close("action")
      })
  }

  return (
    <>
      <Section title="Profile">
        <Row model={props.model} item="profile">
          {me ? (
            <div {...stylex.props(styles.profile)}>
              <Avatar name={name} seed={userAvatarSeed(me)} src={me.photoUrl} size="large" label={`${name}'s photo`} />
              <div {...stylex.props(styles.names)}>
                <span dir="auto" {...stylex.props(styles.name)}>
                  {name}
                </span>
                {me.username ? (
                  <span dir="auto" {...stylex.props(styles.secondary)}>
                    @{me.username}
                  </span>
                ) : null}
              </div>
            </div>
          ) : (
            <Note>Loading your account…</Note>
          )}
        </Row>
      </Section>

      <Section title="Account">
        <Row
          model={props.model}
          item="username"
          control={() => <Note>{me?.username ? <span dir="auto">@{me.username}</span> : "Not set"}</Note>}
        />
        {me?.email ? (
          <Row model={props.model} item="email" control={() => <Note><span dir="auto">{me.email}</span></Note>} />
        ) : null}
      </Section>

      <Section title="Session">
        <Row
          model={props.model}
          item="thisDevice"
          description={props.account.deviceName}
          control={({ titleId }) => (
            <Button variant="destructive" aria-describedby={titleId} onClick={() => dialog.open()}>
              Sign Out…
            </Button>
          )}
        />
      </Section>

      <Dialog
        controller={dialog}
        title="Sign Out?"
        description={signOutWarning(props.pendingCount)}
        closeButton={false}
        footer={
          <>
            <Button onClick={() => dialog.close("button")} disabled={signingOut}>
              Cancel
            </Button>
            <Button variant="destructive" onClick={confirm} disabled={signingOut}>
              {signingOut ? "Signing Out…" : "Sign Out"}
            </Button>
          </>
        }
      />
    </>
  )
}

const styles = stylex.create({
  profile: { display: "flex", alignItems: "center", gap: space.lg, paddingBlock: space.xs },
  names: { display: "flex", flexDirection: "column", gap: space.xxs, minInlineSize: 0 },
  name: { fontSize: font.sizeTitle3, fontWeight: font.weightSemibold, color: color.label },
  secondary: { fontSize: font.sizeCallout, color: color.secondaryLabel },
})
