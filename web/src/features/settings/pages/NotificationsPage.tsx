/** Notifications: the browser permission in plain words, a way to turn it on, sounds and the badge. */

import { userGesture, type Platform } from "@inline/platform"
import { useSignal } from "@inline/reactive/react"
import { Button } from "@inline/ui/react"
import type { PermissionPrompt } from "../../notifications"
import { permissionCopy } from "../format"
import type { PreferencesStore } from "../preferences"
import { Note, Row, Section, SettingSwitch } from "../Rows"
import type { SettingsModel } from "../settings-model"

export function NotificationsPage(props: {
  model: SettingsModel
  preferences: PreferencesStore
  platform: Platform
  prompt: PermissionPrompt
}) {
  const { preferences, prompt } = props
  const permission = useSignal(prompt.permission)
  const copy = permissionCopy(permission, props.platform.info.kind)
  return (
    <>
      <Section title="Notifications">
        <Row
          model={props.model}
          item="notificationPermission"
          description={copy.detail}
          control={({ titleId }) => (
            <>
              <Note tone={permission === "denied" ? "warning" : "strong"} live>
                {copy.status}
              </Note>
              {copy.canAsk ? (
                <Button
                  variant="primary"
                  aria-describedby={titleId}
                  // A real click or key press: browsers refuse prompts without one.
                  onClick={(event) => void prompt.requestPermission(userGesture(event.nativeEvent))}
                >
                  Turn On Notifications
                </Button>
              ) : null}
            </>
          )}
        />
      </Section>

      <Section title="Sound">
        <Row
          model={props.model}
          item="notificationSounds"
          description="Play the system sound with each notification."
          control={(ids) => (
            <SettingSwitch
              value={preferences.notificationSounds}
              onChange={(on) => preferences.setNotificationSounds(on)}
              ids={ids}
            />
          )}
        />
      </Section>

      <Section title="Badge">
        <Row
          model={props.model}
          item="appBadge"
          description="Show the number of important unread chats in the tab title and icon, and on the app icon when Inline is installed."
          control={(ids) => (
            <SettingSwitch value={preferences.appBadge} onChange={(on) => preferences.setAppBadge(on)} ids={ids} />
          )}
        />
      </Section>
    </>
  )
}
