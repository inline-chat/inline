/** Data & Storage: whether the browser keeps Inline's data, how much it uses, and clearing cached media. */

import type { Platform } from "@inline/platform"
import type { ReadSignal } from "@inline/reactive"
import { useElement, useModel, useSignal } from "@inline/reactive/react"
import { Button } from "@inline/ui/react"
import { ClearMediaAction, clearMediaStatusText, refreshEstimateOnShow } from "../controls"
import { formatUsage, persistenceCopy } from "../format"
import { Note, Row, Section } from "../Rows"
import type { SettingsModel } from "../settings-model"

const NONE: ReadSignal<null> = { get: () => null, peek: () => null }

export function DataPage(props: { model: SettingsModel; platform: Platform; onClearCachedMedia?: () => Promise<void> | void }) {
  const storage = props.platform.storage
  const persisted = useSignal(storage.available ? storage.persisted : NONE)
  const estimate = useSignal(storage.available ? storage.estimate : NONE)
  const showRef = useElement(useModel(() => refreshEstimateOnShow(storage), [storage]))
  const action = useModel(
    () =>
      new ClearMediaAction({
        ...(props.onClearCachedMedia ? { clear: props.onClearCachedMedia } : {}),
        ...(storage.available ? { refresh: () => storage.refreshEstimate() } : {}),
      }),
    [props.onClearCachedMedia, storage],
  )
  const status = useSignal(action.status)
  const statusText = clearMediaStatusText(status)
  const persistence = persistenceCopy(storage.available ? persisted : null)
  const usage = !storage.available ? "Not available in this browser" : estimate ? formatUsage(estimate) : "Measuring…"

  return (
    <div ref={showRef}>
      <Section title="Storage">
        <Row model={props.model} item="storageUsage" control={() => <Note live>{usage}</Note>} />
        <Row
          model={props.model}
          item="persistentStorage"
          description={persistence.detail}
          control={() => <Note tone={persisted === false ? "warning" : "strong"}>{persistence.status}</Note>}
        />
        <Row
          model={props.model}
          item="clearCachedMedia"
          description={
            action.available
              ? "Photos, videos and files downloaded to this device. They stay in your chats and download again when you open them."
              : "Not available yet: this build does not keep a media cache it can clear."
          }
          control={({ descriptionId }) => (
            <>
              {statusText ? (
                <Note tone={status === "failed" ? "warning" : "normal"} live>
                  {statusText}
                </Note>
              ) : null}
              <Button
                aria-describedby={descriptionId}
                disabled={!action.available || status === "clearing"}
                onClick={() => void action.run()}
              >
                Clear Cached Media
              </Button>
            </>
          )}
        />
      </Section>
    </div>
  )
}
