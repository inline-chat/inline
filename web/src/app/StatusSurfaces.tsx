/**
 * The window-level status surfaces (`status.ts` decides which): the
 * full-pane screens for outdated, superseded, failed and signed out; the
 * quiet banners for storage; the update affordance in the title strip.
 * Connection states are not here: they replace the chat header's subtitle.
 */

import { userGesture } from "@inline/platform"
import { useSignal } from "@inline/reactive/react"
import { Button, CloseIcon, IconButton } from "@inline/ui/react"
import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import { space } from "@inline/ui/tokens/space.stylex"
import * as stylex from "@stylexjs/stylex"
import { useState } from "react"
import { UpdateIcon } from "./icons"
import type { PermissionPrompt } from "../features/notifications"
import type { AppServices } from "./services"
import { statusBannerText, statusScreenText, type StatusBannerKind, type StatusScreenKind } from "./status"

export function StatusScreen(props: { services: AppServices; screen: StatusScreenKind; failure?: string | undefined }) {
  const text = statusScreenText[props.screen]
  const [copied, setCopied] = useState<"idle" | "copied" | "failed">("idle")
  return (
    <div role="alert" {...stylex.props(styles.screen)}>
      <h2 {...stylex.props(styles.title)}>{text.title}</h2>
      <p {...stylex.props(styles.body)}>{text.body}</p>
      {props.screen === "failed" && props.failure && <p {...stylex.props(styles.detail)}>{props.failure}</p>}
      <div {...stylex.props(styles.actions)}>
        {text.action && (
          <Button variant="primary" onClick={() => props.services.reload()}>
            {text.action}
          </Button>
        )}
        {props.screen === "failed" && (
          <Button
            onClick={() => {
              void props.services.copyDiagnostics().then((ok) => setCopied(ok ? "copied" : "failed"))
            }}
          >
            Copy Diagnostics
          </Button>
        )}
      </div>
      <p role="status" {...stylex.props(styles.detail)}>
        {copied === "copied" ? "Diagnostics copied." : copied === "failed" ? "Couldn't copy the diagnostics." : ""}
      </p>
    </div>
  )
}

export function StatusBanner(props: { banner: StatusBannerKind }) {
  return (
    <div role="status" {...stylex.props(styles.banner, props.banner === "storageFull" && styles.bannerWarning)}>
      {statusBannerText[props.banner]}
    </div>
  )
}

/** "Turn on notifications": a quiet, dismissible banner while the browser has not been asked. Asks only from the click. */
export function NotificationPromptBanner(props: { services: AppServices }) {
  const prompt = useSignal(props.services.notificationPrompt)
  return prompt ? <PromptBanner prompt={prompt} /> : null
}

function PromptBanner(props: { prompt: PermissionPrompt }) {
  const show = useSignal(props.prompt.showPrompt)
  if (!show) return null
  return (
    <div role="region" aria-label="Notifications" {...stylex.props(styles.banner, styles.prompt)}>
      <span {...stylex.props(styles.promptText)}>Get notified about new messages.</span>
      <Button
        size="small"
        variant="primary"
        onClick={(event) => void props.prompt.requestPermission(userGesture(event.nativeEvent))}
      >
        Turn On Notifications
      </Button>
      <IconButton size="small" label="Not Now" icon={<CloseIcon />} onClick={() => props.prompt.dismiss()} />
    </div>
  )
}

/** Words of the update affordance. */
export const updateText = { label: "Update ready: Reload", tooltip: "A new version of Inline is ready. Reload to use it." } as const

/**
 * "Update ready: Reload". Shown only when the platform has a new build
 * waiting; never reloads by itself. The strip's title keeps priority: in a
 * strip narrower than 320 px (the default sidebar is 240 px) it is an icon
 * button with the words as its name and tooltip (`TitleStrip` is a size
 * container).
 */
export function UpdateButton(props: { services: AppServices }) {
  const update = useSignal(props.services.update)
  if (update.status !== "ready") return null
  const apply = () => props.services.applyUpdate()
  return (
    <>
      <Button size="small" variant="plain" icon={<UpdateIcon />} title={updateText.tooltip} onClick={apply} style={styles.updateWide}>
        {updateText.label}
      </Button>
      <IconButton size="small" label={updateText.label} icon={<UpdateIcon />} onClick={apply} style={styles.updateNarrow} />
    </>
  )
}

/** Narrower strips show the update control as an icon (the title would otherwise shrink to a letter). */
const NARROW_STRIP = "@container (max-width: 319px)"

const styles = stylex.create({
  screen: {
    display: "flex",
    flexDirection: "column",
    alignItems: "center",
    justifyContent: "center",
    gap: space.md,
    blockSize: "100%",
    paddingInline: space.huge,
    textAlign: "center",
    backgroundColor: color.windowBackground,
    fontFamily: font.familySystem,
  },
  title: {
    margin: 0,
    color: color.label,
    fontSize: font.sizeTitle2,
    fontWeight: font.weightSemibold,
  },
  body: {
    margin: 0,
    maxInlineSize: "42ch",
    color: color.secondaryLabel,
    fontSize: font.sizeBody,
    lineHeight: font.lineHeightBody,
  },
  detail: {
    margin: 0,
    minBlockSize: "1lh",
    color: color.secondaryLabel,
    fontSize: font.sizeCallout,
  },
  actions: {
    display: "flex",
    gap: space.md,
    marginBlockStart: space.md,
  },
  banner: {
    flexShrink: 0,
    paddingBlock: space.sm,
    paddingInline: space.lg,
    borderBlockEndWidth: 1,
    borderBlockEndStyle: "solid",
    borderBlockEndColor: color.separator,
    backgroundColor: color.controlHover,
    color: color.secondaryLabel,
    fontFamily: font.familySystem,
    fontSize: font.sizeCallout,
  },
  prompt: {
    display: "flex",
    alignItems: "center",
    gap: space.md,
    paddingBlock: space.xs,
  },
  promptText: {
    flexGrow: 1,
    minInlineSize: 0,
  },
  bannerWarning: {
    color: color.label,
  },
  updateWide: {
    display: { default: "inline-flex", [NARROW_STRIP]: "none" },
  },
  updateNarrow: {
    display: { default: "none", [NARROW_STRIP]: "inline-flex" },
  },
})
