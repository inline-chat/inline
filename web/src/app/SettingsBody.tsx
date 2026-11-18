/**
 * The `settings` destination's body, in the settings chunk
 * (`settings-chunk.ts`): `SettingsPaneModel` for the pane (stable
 * `onNavigate`, the account, the shortcut reference) and `SettingsView`. The
 * pane around it is `ChunkPane` (title strip, then this once the chunk is
 * there), so none of this is in the shell's chunk.
 */

import { useModel, useSignal } from "@inline/reactive/react"
import type { Destination } from "@inline/view"
import { detectPlatform } from "@inline/view"
import { SettingsView } from "../features/settings"
import type { PaneViewProps } from "./PaneArea"
import { SettingsPaneModel } from "./settings-pane"

export function SettingsBody(props: Omit<PaneViewProps, "leading">) {
  const { services, shell, paneId } = props
  const model = useModel(
    () =>
      new SettingsPaneModel({
        workspace: shell.session.workspace,
        paneId,
        me: shell.session.me,
        signOut: () => services.runtime.signOut(),
        deviceName: services.deviceName,
        registry: services.runtime.app.registry,
        platform: detectPlatform({ navigator, desktop: false }),
      }),
    [shell, paneId],
  )
  const account = useSignal(model.account)
  const prompt = useSignal(services.notificationPrompt)
  const destination: Extract<Destination, { kind: "settings" }> | undefined =
    props.destination.kind === "settings" ? props.destination : undefined
  if (!account) return null
  return (
    <SettingsView
      page={destination?.page}
      onNavigate={model.openPage}
      appearance={services.appearance}
      platform={services.platform}
      preferences={services.preferences}
      account={account}
      shortcuts={model.shortcuts}
      {...(prompt ? { notificationPrompt: prompt } : {})}
      buildId={services.buildId}
    />
  )
}
