import * as stylex from "@stylexjs/stylex"
import { useEffect, useState } from "react"
import { colors } from "../styles/tokens.stylex"
import { SettingsPage, SettingsRow, SettingsSection } from "./SettingsSection"

const bytes = (value?: number) => {
  if (value == null) return "Unavailable"
  if (value < 1_000_000) return `${Math.round(value / 1_000)} KB`
  if (value < 1_000_000_000) return `${(value / 1_000_000).toFixed(1)} MB`
  return `${(value / 1_000_000_000).toFixed(1)} GB`
}

export function SettingsDataStorageView() {
  const [estimate, setEstimate] = useState<StorageEstimate>()
  const [estimateError, setEstimateError] = useState(false)
  useEffect(() => {
    let active = true
    void navigator.storage.estimate()
      .then((value) => {
        if (active) setEstimate(value)
      })
      .catch(() => {
        if (active) setEstimateError(true)
      })
    return () => {
      active = false
    }
  }, [])

  const opfs = typeof navigator.storage.getDirectory === "function"
  return (
    <SettingsPage title="Data & Storage">
      <SettingsSection title="Local Data">
        <SettingsRow
          title="Structured Replica"
          detail="IndexedDB stores selectively hydrated Inline records and durable pending actions."
        />
        <SettingsRow
          title="Media Cache"
          detail={opfs
            ? "OPFS stores bounded media bytes; IndexedDB remains the capability fallback."
            : "IndexedDB stores bounded media bytes because OPFS is unavailable."}
        />
        <SettingsRow
          title="Browser Storage"
          detail={estimateError
            ? "The browser did not expose a storage estimate."
            : estimate
              ? `${bytes(estimate.usage)} used of approximately ${bytes(estimate.quota)}.`
              : "Calculating local usage…"}
        />
      </SettingsSection>
      <p {...stylex.props(styles.note)}>
        Alpha 1 keeps data local to this browser profile. Cache controls will
        be added only with account-safe, transactional deletion semantics.
      </p>
    </SettingsPage>
  )
}

const styles = stylex.create({
  note: {
    margin: 4,
    color: colors.textTertiary,
    fontSize: 10,
    lineHeight: 1.4,
  },
})
