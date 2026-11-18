/** General: how messages are sent, spelling, and where reply threads open. */

import type { Platform } from "@inline/platform"
import { useSignal } from "@inline/reactive/react"
import { SegmentedControl } from "@inline/ui/react"
import { sendKeyDescription, sendKeyOptions } from "../format"
import type { PreferencesStore } from "../preferences"
import { Row, Section, SettingSwitch } from "../Rows"
import type { SettingsModel } from "../settings-model"

export function GeneralPage(props: { model: SettingsModel; preferences: PreferencesStore; platform: Platform }) {
  const { preferences } = props
  const os = props.platform.info.os
  const sendKey = useSignal(preferences.sendKey)
  return (
    <>
      <Section title="Writing">
        <Row
          model={props.model}
          item="sendMessages"
          description={sendKeyDescription(sendKey, os)}
          control={() => (
            <SegmentedControl
              label="Send Messages"
              options={sendKeyOptions(os)}
              value={sendKey}
              onChange={(value) => preferences.setSendKey(value)}
            />
          )}
        />
        <Row
          model={props.model}
          item="checkSpelling"
          description="Underline misspelled words while composing messages."
          control={(ids) => (
            <SettingSwitch value={preferences.spellCheck} onChange={(on) => preferences.setSpellCheck(on)} ids={ids} />
          )}
        />
      </Section>

      <Section title="Messages">
        <Row
          model={props.model}
          item="replyThreadsInSidePane"
          description="Keep the current chat visible when opening a reply thread."
          control={(ids) => (
            <SettingSwitch
              value={preferences.replyThreadsInSidePane}
              onChange={(on) => preferences.setReplyThreadsInSidePane(on)}
              ids={ids}
            />
          )}
        />
      </Section>
    </>
  )
}
