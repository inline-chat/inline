/**
 * Appearance: the kit's controls in the Mac page's order and wording
 * (Appearance, Sidebar, Message Text, Badges). Message style, the compact
 * toolbar and centered chats are left out until the web views honor them.
 */

import { useSignal } from "@inline/reactive/react"
import type { AppearanceController, UnreadBadgeStyle } from "@inline/ui/theme"
import {
  AppearanceSwitch,
  LineSpacingControl,
  MessageFontControl,
  SegmentedControl,
  type SegmentOption,
  SidebarItemSizeControl,
  TextSizeStepper,
  ThemeSwatchGrid,
} from "@inline/ui/react"
import { Row, Section } from "../Rows"
import type { SettingsModel } from "../settings-model"

const BADGE_OPTIONS: readonly SegmentOption<UnreadBadgeStyle>[] = [
  { value: "dot", label: "Dot" },
  { value: "numbered", label: "Numbered" },
]

export function AppearancePage(props: { model: SettingsModel; appearance: AppearanceController }) {
  const { appearance, model } = props
  const badgeStyle = useSignal(appearance.unreadBadgeStyle)
  return (
    <>
      <Section title="Appearance">
        <Row model={model} item="appearance" control={() => <AppearanceSwitch controller={appearance} />} />
        <Row model={model} item="theme" stacked control={() => <ThemeSwatchGrid controller={appearance} />} />
      </Section>

      <Section title="Sidebar">
        <Row model={model} item="sidebarItemSize" control={() => <SidebarItemSizeControl controller={appearance} />} />
      </Section>

      <Section title="Message Text">
        <Row model={model} item="fonts" control={() => <MessageFontControl controller={appearance} />} />
        <Row model={model} item="fontSize" control={() => <TextSizeStepper controller={appearance} />} />
        <Row model={model} item="lineSpacing" stacked control={() => <LineSpacingControl controller={appearance} />} />
      </Section>

      <Section title="Badges">
        <Row
          model={model}
          item="unreadBadgeStyle"
          description="How the sidebar marks chats with unread messages."
          control={() => (
            <SegmentedControl
              label="Unread Badge Style"
              options={BADGE_OPTIONS}
              value={badgeStyle}
              onChange={(value) => appearance.setUnreadBadgeStyle(value)}
            />
          )}
        />
      </Section>
    </>
  )
}
