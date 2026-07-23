import * as stylex from "@stylexjs/stylex"
import { useState } from "react"
import { useInlineAppearancePreferences } from "~/inline/preferences/InlineAppearancePreferencesContext"
import type { InlineAppearancePreferences } from "~/inline/preferences/InlineAppearancePreferences"
import { colors } from "../styles/tokens.stylex"
import { InlineSegmentedControl } from "~/ui/InlineSegmentedControl"
import { SettingsPage, SettingsRow, SettingsSection } from "./SettingsSection"

export function SettingsAppearanceView() {
  const { preferences, update } = useInlineAppearancePreferences()
  const [error, setError] = useState<string>()
  const change = (patch: Partial<InlineAppearancePreferences>) => {
    setError(undefined)
    try {
      update(patch)
    } catch {
      setError("Inline could not save this appearance setting.")
    }
  }

  return (
    <SettingsPage title="Appearance">
      <SettingsSection title="Interface">
        <SettingsRow
          title="Appearance"
          detail="Follow macOS, or keep Inline light or dark."
          control={
            <InlineSegmentedControl
              label="Appearance"
              value={preferences.appearance}
              options={[
                { value: "system", label: "System" },
                { value: "light", label: "Light" },
                { value: "dark", label: "Dark" },
              ]}
              onChange={(appearance) => change({ appearance })}
            />
          }
        />
      </SettingsSection>
      <SettingsSection title="Sidebar">
        <SettingsRow
          title="Item Size"
          detail="Large rows include message previews; Compact rows use less space."
          control={
            <InlineSegmentedControl
              label="Sidebar item size"
              value={preferences.sidebarItemSize}
              options={[
                { value: "compact", label: "Compact" },
                { value: "large", label: "Large" },
              ]}
              onChange={(sidebarItemSize) => change({ sidebarItemSize })}
            />
          }
        />
      </SettingsSection>
      <SettingsSection title="Messages">
        <SettingsRow
          title="Message Style"
          detail="Choose how messages are arranged in chats."
          control={
            <InlineSegmentedControl
              label="Message style"
              value={preferences.messageStyle}
              options={[
                { value: "bubble", label: "Bubble" },
                { value: "minimal", label: "Minimal" },
              ]}
              onChange={(messageStyle) => change({ messageStyle })}
            />
          }
        />
      </SettingsSection>
      {error ? <p role="alert" {...stylex.props(styles.error)}>{error}</p> : null}
    </SettingsPage>
  )
}

const styles = stylex.create({
  error: {
    margin: 0,
    color: colors.destructive,
    fontSize: 11,
  },
})
