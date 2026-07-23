import { SettingsPage, SettingsRow, SettingsSection } from "./SettingsSection"

export function SettingsAboutView() {
  return (
    <SettingsPage title="About Inline">
      <SettingsSection>
        <SettingsRow title="Inline for Web" detail="v0.1 Alpha 1 candidate" />
        <SettingsRow title="Supported Browser" detail="Current Chromium on macOS" />
      </SettingsSection>
    </SettingsPage>
  )
}
